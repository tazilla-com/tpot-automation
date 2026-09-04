"""The configuration merge, and the only place precedence lives.

WHY THIS FILE EXISTS
    Four channels can set a variable -- a flag, the environment, an answer file
    and a built-in default -- and every one of them was, in the installer this
    project replaces, resolved somewhere different. Precedence is therefore
    implemented exactly once, here, and everything that describes it
    (`install.sh --help`, docs/answer-file.md, docs/variables.md) is documenting
    this file rather than restating a rule of its own.

    The second reason is narrower and sharper. The installer this replaces built
    its configuration by running `sed` over a YAML template to substitute a
    password. A password containing a backslash-n therefore parsed cleanly as
    YAML and silently installed a DIFFERENT password from the one the operator
    typed -- no error, no warning, and no way to tell from the outside. THERE IS
    NO ESCAPING STEP ANYWHERE IN THIS FILE. Values are carried as Python strings
    from the moment they are read to the moment `json.dump` encodes them, and
    the JSON encoder is the only thing that ever escapes anything. What goes in
    comes out, byte for byte, for every byte.

HOW IT IS INVOKED
    python3 lib/config.py merge   ...   the merge; writes three files, prints nothing
    python3 lib/config.py get     ...   read one non-secret value out of the merged document
    python3 lib/config.py secrets ...   base64 of every secret, for the log redactor only
    python3 lib/config.py keys    ...   the variable surface, tab separated

    It is never executed by shebang and never carries the executable bit.

WHAT IT NEVER DOES
    It never prompts. It never writes outside the paths it is given. It never
    prints a supplied value on any path -- not in an error message, not in a
    diagnostic, not even when the problem IS the value's format. Error messages
    name keys, files and line numbers, and nothing else. `get` refuses a
    secret-typed key outright, so a shell caller cannot read a credential out of
    the merged document even by mistake.

EXIT STATUS
     0  success
    10  a user-input error (EX_USAGE in lib/exitcodes.sh)
    40  a bug in this file (EX_INTERNAL in lib/exitcodes.sh)
    `get` additionally uses 1 for "the key is absent from the document", which is
    not an error, and an interrupt exits 130 (128 + SIGINT) so that it can never
    be mistaken for either of the two above. The numbers are duplicated from
    lib/exitcodes.sh because that file is bash and this one is not; a test
    asserts the two agree.

    On a user-input error it reports EVERY problem of the first class it found,
    so somebody with three misspelt keys learns about three.

PYTHON
    3.9 or newer, standard library only. PyYAML is used when it is importable
    and is never required: a .yml answer file on a box without it is a usage
    error naming both fixes, never a silent install.
"""

import base64
import copy
import json
import os
import re
import sys
from string import Formatter

# Duplicated from lib/exitcodes.sh, which is the source of truth. See the
# module docstring: that file is bash and cannot be imported here.
EX_OK = 0
EX_USAGE = 10
EX_INTERNAL = 40
EX_ABSENT = 1

PROG = "config"

SCALAR_TYPES = ("string", "path", "integer", "boolean", "enum")
LIST_TYPES = ("list[string]", "list[integer]")
ALL_TYPES = SCALAR_TYPES + LIST_TYPES + ("map",)

BOOL_TRUE = ("true", "yes", "on", "1")
BOOL_FALSE = ("false", "no", "off", "0")

# The four labels a value's origin can carry in sources.json, plus the two the
# merge itself produces. Nothing else is a valid source.
SRC_FLAG = "flag"
SRC_PASSWORD_FILE = "password-file"
SRC_ENV = "env"
SRC_CONFIG_FILE = "config-file"
SRC_DEFAULT = "default"
SRC_DERIVED = "derived"


class UsageError(Exception):
    """One or more user-input problems. Carries every message in its class."""

    def __init__(self, messages):
        if isinstance(messages, str):
            messages = [messages]
        super().__init__("; ".join(messages))
        self.messages = list(messages)


def _emit(message):
    """One problem, one line, always prefixed. Never carries a value."""
    sys.stderr.write("%s: %s\n" % (PROG, message))


# ---------------------------------------------------------------------------
# The schema
# ---------------------------------------------------------------------------


class Schema:
    """lib/varschema.json, loaded and indexed. Order is significant throughout."""

    def __init__(self, document, path):
        self.path = path
        self.document = document
        self.keys = document.get("keys") or []
        self.by_name = {}
        for key in self.keys:
            name = key.get("name")
            if not name:
                raise UsageError("%s: a key has no name" % path)
            if name in self.by_name:
                raise UsageError("%s: duplicate key '%s'" % (path, name))
            if key.get("type") not in ALL_TYPES:
                raise UsageError("%s: %s: unknown type" % (path, name))
            self.by_name[name] = key
        self.env_prefixes = tuple(document.get("env_prefixes") or ())
        self.env_ignore = frozenset(document.get("env_ignore") or ())
        self.comment_prefix = document.get("comment_key_prefix") or "#"
        self.web_credential_types = tuple(
            document.get("web_credential_install_types") or ()
        )

    @classmethod
    def load(cls, path):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                document = json.load(handle)
        except OSError as exc:
            raise UsageError("%s: cannot be read (%s)" % (path, exc.strerror))
        except UnicodeDecodeError:
            raise UsageError("%s: is not valid UTF-8" % path)
        except json.JSONDecodeError as exc:
            raise UsageError(
                "%s: is not valid JSON (line %d, column %d)" % (path, exc.lineno, exc.colno)
            )
        if not isinstance(document, dict):
            raise UsageError("%s: is not a JSON object" % path)
        return cls(document, path)

    def names(self):
        return [key["name"] for key in self.keys]

    def is_secret(self, name):
        return bool(self.by_name[name].get("secret"))

    def secret_names(self):
        return [k["name"] for k in self.keys if k.get("secret")]

    def flag_for(self, name):
        """The long flag a flag-only key is set with: tpot_log_dir -> --log-dir."""
        stem = name[5:] if name.startswith("tpot_") else name
        return "--" + stem.replace("_", "-")

    def env_name_for(self, name):
        return name.upper()


# ---------------------------------------------------------------------------
# Reading answer files
#
# Two parsers, one shape. YAML when PyYAML is importable, JSON otherwise, and a
# .yml file on a box with no PyYAML is a usage error naming both ways out --
# never a silent skip. Preflight mutates nothing, so there is nothing to undo
# when the run stops here, and an install that quietly ignored your settings is
# a great deal worse than one that refused to start.
# ---------------------------------------------------------------------------


def _import_yaml():
    try:
        import yaml  # noqa: F401  (probed, not used here)
    except ImportError:
        return None
    return yaml


def _looks_like_json(text):
    stripped = text.lstrip()
    return stripped.startswith("{")


def _parse_json_document(text, path):
    """Parse JSON, rejecting a duplicate key at any depth."""
    duplicates = []

    def hook(pairs):
        seen = set()
        for name, _value in pairs:
            if name in seen:
                duplicates.append(name)
            seen.add(name)
        return dict(pairs)

    try:
        document = json.loads(text, object_pairs_hook=hook)
    except json.JSONDecodeError as exc:
        raise UsageError(
            "%s: is not valid JSON (line %d, column %d)" % (path, exc.lineno, exc.colno)
        )
    if duplicates:
        raise UsageError(
            [
                "%s: key '%s' appears more than once; the later one would win silently"
                % (path, name)
                for name in sorted(set(duplicates))
            ]
        )
    # JSON carries no per-key line information that can be recovered without
    # re-implementing the parser, so lines are reported for parse errors only.
    return document, {}


def _parse_yaml_document(yaml_module, text, path):
    """Parse YAML, recording top-level line numbers and rejecting duplicates."""
    try:
        document = yaml_module.safe_load(text)
    except yaml_module.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        where = " (line %d)" % (mark.line + 1) if mark is not None else ""
        raise UsageError("%s: is not valid YAML%s" % (path, where))

    lines = {}
    duplicates = []
    try:
        node = yaml_module.compose(text, Loader=yaml_module.SafeLoader)
    except yaml_module.YAMLError:
        node = None
    if node is not None and isinstance(node, yaml_module.nodes.MappingNode):
        for key_node, _value_node in node.value:
            name = getattr(key_node, "value", None)
            if not isinstance(name, str):
                continue
            if name in lines:
                duplicates.append(name)
            else:
                lines[name] = key_node.start_mark.line + 1
    if duplicates:
        raise UsageError(
            [
                "%s: key '%s' appears more than once (line %d); the later one would win silently"
                % (path, name, lines.get(name, 0))
                for name in sorted(set(duplicates))
            ]
        )
    return document, lines


def read_answer_file(path):
    """Return (mapping, line-numbers). Raises UsageError with every problem found."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise UsageError("%s: cannot be read (%s)" % (path, exc.strerror))
    except UnicodeDecodeError:
        raise UsageError("%s: is not valid UTF-8" % path)

    yaml_module = _import_yaml()
    if yaml_module is not None:
        document, lines = _parse_yaml_document(yaml_module, text, path)
    elif _looks_like_json(text) or path.lower().endswith(".json"):
        document, lines = _parse_json_document(text, path)
    else:
        raise UsageError(
            "%s: reading a YAML answer file needs PyYAML, which is not installed. "
            "Either install it (apt-get install -y python3-yaml) or use a JSON "
            "answer file (examples/tpot.example.json is the shipped starting point)." % path
        )

    if document is None:
        # A file whose every line is a comment is an empty document, and that is
        # exactly what `install.sh --example-config > /root/tpot.yml` produces
        # before it is edited. It sets nothing; it is not malformed.
        document = {}
    if not isinstance(document, dict):
        raise UsageError(
            "%s: must be a flat mapping of variable names to values, not a %s"
            % (path, _type_word(document))
        )
    for name in document:
        if not isinstance(name, str):
            raise UsageError("%s: every key must be a string" % path)
    return document, lines


def _type_word(value):
    """The word for a JSON/YAML type, for an error message. Never the value."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "mapping"
    return type(value).__name__


# ---------------------------------------------------------------------------
# The two file rules, checked rather than merely documented
# ---------------------------------------------------------------------------


def _is_inside(path, directory):
    resolved = os.path.realpath(path)
    root = os.path.realpath(directory)
    return resolved == root or resolved.startswith(root + os.sep)


def check_location_rule(path, repo_dir):
    """An answer file inside the tree is how an inventory became a credential store."""
    if repo_dir and _is_inside(path, repo_dir):
        return (
            "%s: is inside the repository tree (%s). Keep answer files outside it: "
            "a file in the tree is committed by accident, and this one holds your "
            "configuration." % (path, os.path.realpath(repo_dir))
        )
    return None


def check_permission_rule(path):
    """A file that supplies a secret must be root-owned and 0600 or 0400."""
    try:
        info = os.stat(path)
    except OSError as exc:
        return "%s: cannot be inspected (%s)" % (path, exc.strerror)
    mode = info.st_mode & 0o777
    if info.st_uid != 0 or mode not in (0o600, 0o400):
        return (
            "%s: supplies a secret, so it must be owned by root and mode 0600 or 0400; "
            "it is owned by uid %d and mode %04o" % (path, info.st_uid, mode)
        )
    return None


# ---------------------------------------------------------------------------
# Coercion and validation
# ---------------------------------------------------------------------------


def coerce_from_string(key, raw):
    """A string from the environment, --set or a password file -> a typed value.

    Returns (value, error). The error names the key and the wanted type and
    never repeats the value.
    """
    name = key["name"]
    kind = key["type"]

    if raw == "null":
        return None, None

    if kind in ("string", "path"):
        return raw, None

    if kind == "integer":
        if not re.match(r"^-?[0-9]+$", raw):
            return None, "%s: wanted a whole number" % name
        return int(raw), None

    if kind == "boolean":
        lowered = raw.strip().lower()
        if lowered in BOOL_TRUE:
            return True, None
        if lowered in BOOL_FALSE:
            return False, None
        return None, "%s: wanted a boolean (true/false, yes/no, on/off, 1/0)" % name

    if kind == "enum":
        choices = key.get("choices") or []
        if raw not in choices:
            return None, "%s: wanted one of %s" % (name, " ".join(choices))
        return raw, None

    if kind in LIST_TYPES:
        if raw.lstrip().startswith("["):
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                return None, "%s: wanted a JSON array or a comma-separated list" % name
            if not isinstance(parsed, list):
                return None, "%s: wanted a JSON array or a comma-separated list" % name
            items = parsed
        elif raw == "":
            items = []
        else:
            items = [part.strip() for part in raw.split(",")]
        return _coerce_list_items(name, kind, items)

    if kind == "map":
        if not raw.lstrip().startswith("{"):
            return None, "%s: wanted a JSON object" % name
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return None, "%s: wanted a JSON object" % name
        if not isinstance(parsed, dict):
            return None, "%s: wanted a JSON object" % name
        return _check_map(name, parsed)

    return None, "%s: has an unknown type in the schema" % name


def _coerce_list_items(name, kind, items):
    result = []
    for item in items:
        if kind == "list[integer]":
            if isinstance(item, bool):
                return None, "%s: wanted a list of whole numbers" % name
            if isinstance(item, int):
                result.append(item)
                continue
            if isinstance(item, str) and re.match(r"^-?[0-9]+$", item.strip()):
                result.append(int(item.strip()))
                continue
            return None, "%s: wanted a list of whole numbers" % name
        if not isinstance(item, str):
            return None, "%s: wanted a list of strings" % name
        result.append(item)
    return result, None


def _check_map(name, mapping):
    for map_key, map_value in mapping.items():
        if not isinstance(map_key, str) or not isinstance(map_value, str):
            return None, "%s: wanted an object whose keys and values are all strings" % name
    return dict(mapping), None


def check_typed(key, value):
    """A value that arrived already typed, from an answer file. Returns an error or None."""
    name = key["name"]
    kind = key["type"]

    if value is None:
        return None

    if kind in ("string", "path", "enum"):
        if isinstance(value, bool):
            return (
                "%s: found a boolean, wanted text. In YAML, bare yes/no/on/off are "
                "booleans: quote the value." % name
            )
        if not isinstance(value, str):
            return "%s: found %s, wanted text" % (name, _type_word(value))
        return None

    if kind == "integer":
        if isinstance(value, bool) or not isinstance(value, int):
            return "%s: found %s, wanted a whole number" % (name, _type_word(value))
        return None

    if kind == "boolean":
        if not isinstance(value, bool):
            return "%s: found %s, wanted a boolean" % (name, _type_word(value))
        return None

    if kind in LIST_TYPES:
        if not isinstance(value, list):
            return "%s: found %s, wanted a list" % (name, _type_word(value))
        _coerced, error = _coerce_list_items(name, kind, value)
        return error

    if kind == "map":
        if not isinstance(value, dict):
            return "%s: found %s, wanted a mapping" % (name, _type_word(value))
        _coerced, error = _check_map(name, value)
        return error

    return "%s: has an unknown type in the schema" % name


def validate(key, value):
    """Final validation of a merged value. Returns an error message or None."""
    name = key["name"]
    kind = key["type"]

    if value is None:
        return None

    if isinstance(value, str):
        if value == "":
            return (
                "%s: is empty. Supply a value, or set it to null to mean "
                "'leave this alone'." % name
            )
        if kind == "enum":
            choices = key.get("choices") or []
            if value not in choices:
                return "%s: wanted one of %s" % (name, " ".join(choices))
        pattern = key.get("pattern")
        if pattern and not re.match(pattern, value):
            # A regex refusal is the least actionable message this file can
            # produce: the user is told the form is wrong and not what the
            # right form is, and the pattern itself is not something to print
            # at somebody. So a key may carry `pattern_help`, one sentence
            # written for the person who just typed the wrong thing.
            #
            # tpot_upstream_ref is why this exists. Its pattern refuses an
            # ABBREVIATED commit sha, and the reason is three steps deep --
            # ansible.builtin.git accepts a short sha and leaves HEAD at the
            # full one, so upstream's own re-run check then compares seven
            # characters against forty and exits 1 on every second run. No
            # generic message could ever lead somebody to that.
            help_text = key.get("pattern_help")
            if help_text:
                return "%s: %s" % (name, help_text)
            return "%s: is not in the form this variable requires" % name
        return None

    if isinstance(value, int) and not isinstance(value, bool):
        low = key.get("min")
        high = key.get("max")
        if low is not None and value < low:
            return "%s: is below the minimum of %d" % (name, low)
        if high is not None and value > high:
            return "%s: is above the maximum of %d" % (name, high)
        return None

    if isinstance(value, list):
        for item in value:
            if isinstance(item, str) and item == "":
                return "%s: contains an empty entry" % name
        return None

    return None


# ---------------------------------------------------------------------------
# The merge
# ---------------------------------------------------------------------------


class Supplied:
    """One value, where it came from, and how it arrived."""

    def __init__(self, value, source, detail, typed):
        self.value = value
        self.source = source
        self.detail = detail
        self.typed = typed  # True when the channel already gave us a typed value


def _strip_one_newline(text):
    """Exactly one trailing newline, never more. Byte identity is the point."""
    if text.endswith("\n"):
        return text[:-1]
    return text


def _read_secret_file(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        raise UsageError("%s: cannot be read (%s)" % (path, exc.strerror))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise UsageError("%s: is not valid UTF-8" % path)
    return _strip_one_newline(text)


def _warn_if_carriage_return(value, where):
    """A CRLF file yields a value ending in a carriage return. Say so, do not fix it.

    Silently trimming it would be an escaping step, and this file has none. The
    warning describes the FILE's line endings; it does not reveal the value.
    """
    if value.endswith("\r"):
        sys.stderr.write(
            "%s: %s: the value ends with a carriage return; the file appears to use "
            "CRLF line endings. It is used exactly as it is.\n" % (PROG, where)
        )


def collect_config_files(schema, paths, repo_dir):
    """Read every answer file, apply both file rules, return per-file mappings."""
    errors = []
    results = []
    for path in paths:
        location_error = check_location_rule(path, repo_dir)
        if location_error:
            errors.append(location_error)
            continue
        try:
            document, lines = read_answer_file(path)
        except UsageError as exc:
            errors.extend(exc.messages)
            continue
        supplies_secret = any(
            name in schema.by_name and schema.is_secret(name)
            for name in document
            if not name.startswith(schema.comment_prefix)
        )
        if supplies_secret:
            permission_error = check_permission_rule(path)
            if permission_error:
                errors.append(permission_error)
                continue
        results.append((path, document, lines))
    if errors:
        raise UsageError(errors)
    return results


def merge_channels(schema, files, overrides, use_env):
    """Apply every channel in ascending precedence. Returns {name: Supplied}."""
    supplied = {}
    errors = []

    # 1. answer files, in the order they were given; a later file wins.
    for path, document, lines in files:
        for name, value in document.items():
            if name.startswith(schema.comment_prefix):
                continue
            key = schema.by_name.get(name)
            if key is None:
                where = " (line %d)" % lines[name] if name in lines else ""
                errors.append(
                    "%s: unknown key '%s'%s. Run `install.sh --example-config` for "
                    "the list this installer understands." % (path, name, where)
                )
                continue
            if not key.get("config_file", True):
                errors.append(
                    "%s: '%s' cannot be set in an answer file; use %s on the command "
                    "line. The transcript is opened before any answer file is read."
                    % (path, name, schema.flag_for(name))
                )
                continue
            supplied[name] = Supplied(value, SRC_CONFIG_FILE, path, True)

    # 2. the environment. The name is the variable name, uppercased; there is no
    #    lookup table to drift and therefore none to get wrong.
    if use_env:
        for env_name in sorted(os.environ):
            if not env_name.startswith(schema.env_prefixes):
                continue
            if env_name in schema.env_ignore:
                sys.stderr.write(
                    "%s: %s belongs to upstream T-Pot, not to this installer; ignoring it.\n"
                    % (PROG, env_name)
                )
                continue
            name = env_name.lower()
            key = schema.by_name.get(name)
            if key is None:
                errors.append(
                    "%s is not a variable this installer knows. The environment name "
                    "is the variable name uppercased; check the spelling against "
                    "`install.sh --example-config`." % env_name
                )
                continue
            if not key.get("env", True):
                errors.append(
                    "%s is not read from the environment; use %s %s on the command line."
                    % (
                        env_name,
                        schema.flag_for(name),
                        "DIR" if key.get("type") == "path" else "VALUE",
                    )
                )
                continue
            supplied[name] = Supplied(os.environ[env_name], SRC_ENV, env_name, False)

    # 3. the flag level, in command-line order; a later one wins.
    for override in overrides:
        supplied[override.name] = override.as_supplied()

    if errors:
        raise UsageError(errors)
    return supplied


def coerce_all(schema, supplied):
    """Turn every string-channel value into its schema type."""
    errors = []
    values = {}
    sources = {}
    for name in schema.names():
        entry = supplied.get(name)
        if entry is None:
            continue
        key = schema.by_name[name]
        if entry.typed:
            error = check_typed(key, entry.value)
            if error:
                errors.append(_with_origin(error, entry))
                continue
            value = entry.value
            if isinstance(value, list):
                value, _ = _coerce_list_items(name, key["type"], value)
            elif isinstance(value, dict):
                value, _ = _check_map(name, value)
        else:
            value, error = coerce_from_string(key, entry.value)
            if error:
                errors.append(_with_origin(error, entry))
                continue
        values[name] = value
        sources[name] = {"source": entry.source}
        if entry.detail is not None:
            sources[name]["detail"] = entry.detail
    if errors:
        raise UsageError(errors)
    return values, sources


def _with_origin(message, entry):
    """Attach where the value came from, so a bad value is findable."""
    if entry.source == SRC_CONFIG_FILE:
        return "%s: %s" % (entry.detail, message)
    if entry.source == SRC_ENV:
        return "%s (from %s)" % (message, entry.detail)
    if entry.source == SRC_PASSWORD_FILE:
        return "%s (from %s)" % (message, entry.detail)
    return "%s (from %s)" % (message, entry.detail or "the command line")


def apply_defaults(schema, values, sources):
    """Fill in defaults and the three derivations, in schema order.

    A key with no default and no supplied value is OMITTED from the document
    entirely -- it is not written as null. The distinction is load-bearing: the
    Ansible side asks `is defined` for exactly these keys, so that a per-release
    data file can supply what we do not know. Never write null for "unknown".
    """
    internal_errors = []
    derived_errors = []

    for key in schema.keys:
        name = key["name"]
        if name in values:
            continue

        if "default_from" in key:
            source_key = key["default_from"]
            if source_key not in values:
                continue
            values[name] = copy.deepcopy(values[source_key])
            sources[name] = {"source": SRC_DERIVED, "detail": source_key}
        elif "default_eq" in key:
            rule = key["default_eq"]
            source_key = rule.get("key")
            if source_key not in values:
                continue
            values[name] = values[source_key] == rule.get("equals")
            sources[name] = {"source": SRC_DERIVED, "detail": source_key}
        elif "default_format" in key:
            template = key["default_format"]
            fields = [f for _lit, f, _spec, _conv in Formatter().parse(template) if f]
            if any(f not in values or values[f] is None for f in fields):
                continue
            values[name] = template.format(**{f: values[f] for f in fields})
            sources[name] = {"source": SRC_DERIVED, "detail": ",".join(fields)}
        elif "default" in key:
            values[name] = copy.deepcopy(key["default"])
            sources[name] = {"source": SRC_DEFAULT}
        else:
            continue

        error = validate(key, values[name])
        if error:
            if sources[name]["source"] == SRC_DERIVED:
                derived_errors.append(
                    "%s (derived from %s)" % (error, sources[name]["detail"])
                )
            else:
                internal_errors.append("%s: the shipped default is invalid" % name)

    if derived_errors:
        raise UsageError(derived_errors)
    if internal_errors:
        for message in internal_errors:
            _emit(message)
        sys.exit(EX_INTERNAL)


def validate_all(schema, values, sources):
    errors = []
    for name in schema.names():
        if name not in values:
            continue
        if sources.get(name, {}).get("source") in (SRC_DEFAULT, SRC_DERIVED):
            continue  # already validated where it was produced
        error = validate(schema.by_name[name], values[name])
        if error:
            entry = sources.get(name, {})
            detail = entry.get("detail")
            if entry.get("source") == SRC_CONFIG_FILE and detail:
                errors.append("%s: %s" % (detail, error))
            elif detail:
                errors.append("%s (from %s)" % (error, detail))
            else:
                errors.append(error)
    if errors:
        raise UsageError(errors)


# The wording of this message is fixed, and lib/args.sh carries the same text
# for the case it catches first (step 1, before a transcript exists). The two
# must stay identical: a user who hits one and then the other must not be told
# two different things. Only the `config: ` prefix differs, and that is this
# file's own marker on every line it writes.
_MISSING_WEB_PASSWORD = (
    "tpot_web_password is required and was not supplied.",
    "Set it one of three ways:",
    "  --web-password-file /root/.tpot-web-pw   (root-owned, 0600)",
    "  TPOT_WEB_PASSWORD=...                    (environment)",
    '  tpot_web_password: "..."                 in --config /root/tpot.yml',
    "Run `install.sh --example-config > /root/tpot.yml` for a starting point.",
)


def _missing_message(schema, name):
    if name == "tpot_web_password":
        return list(_MISSING_WEB_PASSWORD)
    return [
        "%s is required and was not supplied." % name,
        "Set it one of three ways:",
        "  %s-file PATH   (a PATH, root-owned and 0600 -- never a value)"
        % schema.flag_for(name),
        "  %s=...   (environment)" % schema.env_name_for(name),
        '  %s: "..."   in --config /root/tpot.yml' % name,
        "Run `install.sh --example-config > /root/tpot.yml` for a starting point.",
    ]


def check_required(schema, values, optional):
    """The one required key, and only for the install types that have a dashboard."""
    errors = []
    install_type = values.get("tpot_install_type")
    for key in schema.keys:
        name = key["name"]
        if not key.get("required") or name in optional:
            continue
        if name == "tpot_web_password":
            if schema.web_credential_types and install_type not in schema.web_credential_types:
                continue
        if name in values and values[name] is not None:
            continue
        errors.extend(_missing_message(schema, name))
    if errors:
        raise UsageError(errors)


# ---------------------------------------------------------------------------
# Writing the three documents
# ---------------------------------------------------------------------------


def write_private_json(path, payload):
    """Create at 0600 before a byte is written; never widen an existing file."""
    try:
        if os.path.lexists(path):
            os.unlink(path)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as exc:
        raise UsageError("%s: cannot be written (%s)" % (path, exc.strerror))
    try:
        handle = os.fdopen(descriptor, "w", encoding="utf-8")
    except OSError:
        os.close(descriptor)
        raise
    with handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


# ---------------------------------------------------------------------------
# Command-line parsing
#
# Hand rolled rather than argparse for one reason that matters: --set,
# --password-file and --secret-stdin all sit at the same precedence level, so
# "a later one wins" has to compare them against EACH OTHER in command-line
# order. An argparse `append` action gives one list per option and loses that.
# ---------------------------------------------------------------------------


class Override:
    """One flag-level assignment, in the order it appeared."""

    def __init__(self, name, value, source, detail, typed=False):
        self.name = name
        self.value = value
        self.source = source
        self.detail = detail
        self.typed = typed

    def as_supplied(self):
        return Supplied(self.value, self.source, self.detail, self.typed)


def _need_value(argv, index, option):
    if index + 1 >= len(argv):
        raise UsageError("%s needs a value" % option)
    return argv[index + 1]


def parse_merge_args(argv, schema_loader):
    """Returns a dict of options. Raises UsageError with every problem found."""
    options = {
        "schema": None,
        "repo_dir": None,
        "out": None,
        "public_out": None,
        "sources_out": None,
        "configs": [],
        "overrides": [],
        "optional": [],
        "use_env": True,
        "secret_stdin_key": None,
    }
    errors = []
    index = 0
    schema = None
    pending_set_index = None

    # --schema must be resolved first: every other option is validated against it.
    for position, argument in enumerate(argv):
        if argument == "--schema" and position + 1 < len(argv):
            options["schema"] = argv[position + 1]
            break
    if options["schema"] is None:
        raise UsageError("merge needs --schema PATH")
    schema = schema_loader(options["schema"])

    while index < len(argv):
        argument = argv[index]
        if argument == "--schema":
            _need_value(argv, index, argument)
            index += 2
            continue
        if argument in ("--repo-dir", "--out", "--public-out", "--sources-out"):
            value = _need_value(argv, index, argument)
            options[argument[2:].replace("-", "_")] = value
            index += 2
            continue
        if argument in ("-c", "--config"):
            options["configs"].append(_need_value(argv, index, argument))
            index += 2
            continue
        if argument == "--set":
            assignment = _need_value(argv, index, argument)
            if "=" not in assignment:
                errors.append("--set wants KEY=VALUE")
                index += 2
                continue
            name, value = assignment.split("=", 1)
            key = schema.by_name.get(name)
            if key is None:
                errors.append("--set: '%s' is not a variable this installer knows" % name)
            elif key.get("secret"):
                errors.append(
                    "--set: '%s' is a secret and cannot be set this way. A command-line "
                    "argument is world-readable in /proc for the lifetime of the process, "
                    "and an install runs for 30 to 90 minutes. Use %s-file PATH, %s in "
                    "the environment, or an answer file."
                    % (name, schema.flag_for(name), schema.env_name_for(name))
                )
            else:
                options["overrides"].append(Override(name, value, SRC_FLAG, "--set"))
                pending_set_index = len(options["overrides"]) - 1
            index += 2
            continue
        if argument == "--set-detail":
            value = _need_value(argv, index, argument)
            if pending_set_index is None:
                errors.append("--set-detail must follow a --set")
            else:
                options["overrides"][pending_set_index].detail = value
            index += 2
            continue
        if argument == "--password-file":
            assignment = _need_value(argv, index, argument)
            if "=" not in assignment:
                errors.append("--password-file wants KEY=PATH")
                index += 2
                continue
            name, path = assignment.split("=", 1)
            key = schema.by_name.get(name)
            if key is None:
                errors.append(
                    "--password-file: '%s' is not a variable this installer knows" % name
                )
            elif not key.get("secret"):
                errors.append(
                    "--password-file: '%s' is not a secret key; use --set %s=VALUE" % (name, name)
                )
            else:
                options["overrides"].append(
                    Override(name, path, SRC_PASSWORD_FILE, path)
                )
            pending_set_index = None
            index += 2
            continue
        if argument == "--secret-stdin":
            name = _need_value(argv, index, argument)
            key = schema.by_name.get(name)
            if options["secret_stdin_key"] is not None:
                errors.append("--secret-stdin may be given at most once")
            elif key is None:
                errors.append("--secret-stdin: '%s' is not a variable this installer knows" % name)
            elif not key.get("secret"):
                errors.append("--secret-stdin: '%s' is not a secret key" % name)
            else:
                options["secret_stdin_key"] = name
                options["overrides"].append(
                    Override(name, None, SRC_FLAG, "--secret-stdin")
                )
            pending_set_index = None
            index += 2
            continue
        if argument == "--optional":
            name = _need_value(argv, index, argument)
            if name not in schema.by_name:
                errors.append("--optional: '%s' is not a variable this installer knows" % name)
            else:
                options["optional"].append(name)
            index += 2
            continue
        if argument == "--no-env":
            options["use_env"] = False
            index += 1
            continue
        errors.append("unknown option '%s'" % argument)
        index += 1

    for required in ("repo_dir", "out", "public_out", "sources_out"):
        if not options[required]:
            errors.append("merge needs --%s PATH" % required.replace("_", "-"))
    if errors:
        raise UsageError(errors)
    options["schema_object"] = schema
    return options


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_merge(argv):
    options = parse_merge_args(argv, Schema.load)
    schema = options["schema_object"]

    # Resolve the flag-level values that come from somewhere other than argv.
    # This happens after parsing so that a usage error is reported before any
    # file is opened, and it is the only place stdin is ever read.
    file_errors = []
    for override in options["overrides"]:
        if override.source == SRC_PASSWORD_FILE:
            path = override.detail
            location_error = check_location_rule(path, options["repo_dir"])
            if location_error:
                file_errors.append(location_error)
                continue
            permission_error = check_permission_rule(path)
            if permission_error:
                file_errors.append(permission_error)
                continue
            try:
                override.value = _read_secret_file(path)
            except UsageError as exc:
                file_errors.extend(exc.messages)
                continue
            _warn_if_carriage_return(override.value, path)
        elif override.detail == "--secret-stdin":
            raw = sys.stdin.buffer.read()
            try:
                override.value = _strip_one_newline(raw.decode("utf-8"))
            except UnicodeDecodeError:
                file_errors.append("--secret-stdin: the value on stdin is not valid UTF-8")
                continue
            _warn_if_carriage_return(override.value, "--secret-stdin")

    files = []
    try:
        files = collect_config_files(schema, options["configs"], options["repo_dir"])
    except UsageError as exc:
        file_errors.extend(exc.messages)
    if file_errors:
        raise UsageError(file_errors)

    supplied = merge_channels(schema, files, options["overrides"], options["use_env"])
    values, sources = coerce_all(schema, supplied)
    validate_all(schema, values, sources)
    apply_defaults(schema, values, sources)
    check_required(schema, values, options["optional"])

    ordered = [name for name in schema.names() if name in values]
    merged = {name: values[name] for name in ordered}
    public = {name: values[name] for name in ordered if not schema.is_secret(name)}
    provenance = {name: sources[name] for name in ordered}

    write_private_json(options["out"], merged)
    write_private_json(options["public_out"], public)
    write_private_json(options["sources_out"], provenance)
    return EX_OK


def _load_merged(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except OSError as exc:
        raise UsageError("%s: cannot be read (%s)" % (path, exc.strerror))
    except UnicodeDecodeError:
        raise UsageError("%s: is not valid UTF-8" % path)
    except json.JSONDecodeError:
        raise UsageError("%s: is not valid JSON" % path)
    if not isinstance(document, dict):
        raise UsageError("%s: is not a JSON object" % path)
    return document


def _two_paths(argv, command, extra_flags=()):
    """Shared parsing for the read-only subcommands."""
    options = {"schema": None, "from": None, "json": False, "positional": []}
    index = 0
    errors = []
    while index < len(argv):
        argument = argv[index]
        if argument == "--schema":
            options["schema"] = _need_value(argv, index, argument)
            index += 2
            continue
        if argument == "--from":
            options["from"] = _need_value(argv, index, argument)
            index += 2
            continue
        if argument == "--json" and "--json" in extra_flags:
            options["json"] = True
            index += 1
            continue
        if argument.startswith("-"):
            errors.append("unknown option '%s'" % argument)
            index += 1
            continue
        options["positional"].append(argument)
        index += 1
    if not options["schema"]:
        errors.append("%s needs --schema PATH" % command)
    if errors:
        raise UsageError(errors)
    return options


def cmd_get(argv):
    options = _two_paths(argv, "get", extra_flags=("--json",))
    if not options["from"]:
        raise UsageError("get needs --from PATH")
    if len(options["positional"]) != 1:
        raise UsageError("get wants exactly one KEY")
    name = options["positional"][0]
    schema = Schema.load(options["schema"])
    key = schema.by_name.get(name)
    if key is None:
        raise UsageError("'%s' is not a variable this installer knows" % name)
    if key.get("secret"):
        raise UsageError(
            "'%s' is a secret and this subcommand never prints one. Secrets reach "
            "the shell only through `config.py secrets`, base64 encoded, for the "
            "log redactor." % name
        )
    document = _load_merged(options["from"])
    if name not in document:
        return EX_ABSENT
    value = document[name]
    if isinstance(value, (list, dict)):
        if not options["json"]:
            raise UsageError("'%s' is a list or a mapping; use --json" % name)
        sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        return EX_OK
    if options["json"]:
        sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        return EX_OK
    if value is None:
        sys.stdout.write("\n")
    elif isinstance(value, bool):
        sys.stdout.write("true\n" if value else "false\n")
    else:
        sys.stdout.write("%s\n" % value)
    return EX_OK


def cmd_secrets(argv):
    options = _two_paths(argv, "secrets")
    if not options["from"]:
        raise UsageError("secrets needs --from PATH")
    if options["positional"]:
        raise UsageError("secrets takes no positional arguments")
    schema = Schema.load(options["schema"])
    document = _load_merged(options["from"])
    for name in schema.secret_names():
        value = document.get(name)
        if not isinstance(value, str) or value == "":
            continue
        encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
        sys.stdout.write(encoded + "\n")
    return EX_OK


def cmd_keys(argv):
    options = _two_paths(argv, "keys")
    if options["positional"]:
        raise UsageError("keys takes no positional arguments")
    schema = Schema.load(options["schema"])
    for key in schema.keys:
        if "default" in key:
            shown = json.dumps(key["default"], ensure_ascii=False, separators=(",", ":"))
        elif "default_from" in key or "default_eq" in key or "default_format" in key:
            shown = "derived"
        else:
            shown = "-"
        sys.stdout.write(
            "%s\t%s\t%s\t%s\t%s\t%s\n"
            % (
                key["name"],
                key["type"],
                "secret" if key.get("secret") else "public",
                "required" if key.get("required") else "optional",
                "env" if key.get("env", True) else "no-env",
                shown,
            )
        )
    return EX_OK


USAGE = """usage: python3 lib/config.py <subcommand> [options]

  merge    --schema PATH --repo-dir PATH --out PATH --public-out PATH
           --sources-out PATH [--config PATH]... [--set KEY=VALUE]...
           [--set-detail FLAG] [--password-file KEY=PATH]...
           [--secret-stdin KEY] [--optional KEY]... [--no-env]
  get      --schema PATH --from PATH [--json] KEY
  secrets  --schema PATH --from PATH
  keys     --schema PATH

Precedence, highest first: --set and flags, the environment, --config files
(a later file wins), the built-in default."""


def main(argv):
    if not argv:
        _emit("a subcommand is required")
        sys.stderr.write(USAGE + "\n")
        return EX_USAGE
    command, rest = argv[0], argv[1:]
    handlers = {
        "merge": cmd_merge,
        "get": cmd_get,
        "secrets": cmd_secrets,
        "keys": cmd_keys,
    }
    handler = handlers.get(command)
    if handler is None:
        _emit("'%s' is not a subcommand" % command)
        sys.stderr.write(USAGE + "\n")
        return EX_USAGE
    try:
        return handler(rest)
    except UsageError as exc:
        for message in exc.messages:
            _emit(message)
        return EX_USAGE


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except KeyboardInterrupt:
        # 128 + SIGINT, the shell's own convention. Deliberately NOT 10 or 40:
        # an interrupt is neither a usage error nor a bug, and install.sh's own
        # INT trap owns the outcome anyway -- it exits 30 and writes
        # result.json whatever this process returned.
        _emit("interrupted")
        sys.exit(130)
    except BaseException:  # noqa: BLE001 -- deliberate: report location, never content
        _exc_type, _exc_value, _tb = sys.exc_info()
        _last = _tb
        while _last is not None and _last.tb_next is not None:
            _last = _last.tb_next
        _where = "unknown"
        if _last is not None:
            _where = "%s:%d" % (
                os.path.basename(_last.tb_frame.f_code.co_filename),
                _last.tb_lineno,
            )
        # The message is deliberately absent: an exception's text can quote the
        # document that produced it, and that document holds a password.
        _emit("internal error: %s at %s -- please file an issue" % (_exc_type.__name__, _where))
        sys.exit(EX_INTERNAL)
