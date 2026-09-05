# SPDX-License-Identifier: Apache-2.0
"""Lexing support for the tests/check-*.sh build gates.

WHY THIS FILE EXISTS
    A gate that greps raw lines is wrong in both directions at once. It fires
    on the word "password" in a paragraph explaining why passwords are never
    on a command line, and it misses a real violation split across a
    backslash continuation. Both failures are worse than no gate: the first
    trains everyone to ignore the gate, the second is the leak it was
    written to stop.

    So the gates do not look at raw lines. They ask this file for the parts
    of a file that are CODE, with comments removed, quote state tracked,
    heredoc bodies separated out, and logical lines already joined.

INVOCATION
    python3 tests/gate-strip.py <mode> <path>

    It is invoked as an argument to python3, never by shebang, and carries no
    executable bit -- the same rule lib/config.py follows.

MODES
    shell    a shell script. Comments are removed with the quote state
             tracked, so a `#` inside '...' or "..." is not a comment.
             Backslash continuations are joined into one logical line.
    shellq1  the same as `shell`, except that the interior of every
             SINGLE-quoted string is emptied. Single quotes cannot contain an
             expansion or a command substitution, so nothing executable is
             lost -- but a printf format string stops contributing stray
             parentheses to a naive command-splitter, which is what it was
             added for.
    shellq   the same, and then the INTERIOR of every quoted string is
             emptied, so '...' becomes '' and "..." becomes "". Use it when
             the question is "what command is this line running", because a
             gate that greps raw text finds the word `read` in the sentence
             "could not read the matrix" and reports a prompt that is not
             there. Its cost is the mirror image: a token that matters and
             lives inside quotes is invisible in this mode, so a gate that
             needs both asks for both.
    md       a Markdown document. Only fenced code blocks (``` or ~~~) are
             reported as code; ordinary prose is reported as prose.
    yaml     a YAML file. Lines inside the scalar of a shell-running module
             key (shell:, command:, raw:, cmd:, script:, and their
             ansible.builtin.* spellings) are reported as code; the rest is
             prose.
    raw      every line, verbatim, as code. For gates whose rule really is
             "this string appears nowhere", prose included.

OUTPUT
    One record per line, three tab-separated fields:

        <first physical line number> <TAB> <kind> <TAB> <text>

    kind is one of:
        code      executable text. For `shell`, comments are already gone and
                  continuations are already joined, so <text> is a complete
                  logical line and the line number is where it STARTS.
        heredoc   the body of a here-document. It is data, not code, but a
                  gate may still want to look at it, so it is reported
                  rather than dropped.
        prose     everything a gate should not treat as executable.

    A tab or a newline inside <text> would corrupt the record, so tabs are
    replaced by a single space. Nothing else is altered: the gates need the
    original characters to report a truthful match.

WHAT IT DOES NOT DO
    It is a lexer, not a parser. It knows quotes, comments, line
    continuations and here-document boundaries. It does not know operator
    precedence, function scope or whether a name is a command or a variable.
    Every gate that needs more than that says so in its own header and
    accepts that its rule is a proxy.
"""

import sys

_SHELL_MODES = ("shell", "shellq", "shellq1", "md", "yaml", "raw")

_YAML_SHELL_KEYS = (
    "shell", "command", "raw", "cmd", "script",
    "ansible.builtin.shell", "ansible.builtin.command",
    "ansible.builtin.raw", "ansible.builtin.script",
    "ansible.legacy.shell", "ansible.legacy.command",
)


def _emit(records, lineno, kind, text):
    records.append("%d\t%s\t%s" % (lineno, kind, text.replace("\t", " ")))


def _heredoc_delims(fragment):
    """Every here-document delimiter opened on this logical line, in order.

    Returns a list of (delimiter, strip_leading_tabs). `<<<` is a here-string
    and opens nothing. Quotes around the delimiter change expansion inside
    the body, which does not matter here, so they are simply removed.
    """
    out = []
    i = 0
    n = len(fragment)
    quote = ""
    while i < n:
        ch = fragment[i]
        if quote:
            if ch == "\\" and quote == '"':
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch == "\\":
            i += 2
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            continue
        if ch == "<" and fragment[i:i + 3] == "<<<":
            i += 3
            continue
        if ch == "<" and fragment[i:i + 2] == "<<":
            i += 2
            strip = False
            if i < n and fragment[i] == "-":
                strip = True
                i += 1
            while i < n and fragment[i] in " \t":
                i += 1
            delim = []
            while i < n:
                c = fragment[i]
                if c in "'\"":
                    q = c
                    i += 1
                    while i < n and fragment[i] != q:
                        delim.append(fragment[i])
                        i += 1
                    i += 1
                    continue
                if c == "\\":
                    i += 1
                    if i < n:
                        delim.append(fragment[i])
                        i += 1
                    continue
                if c.isalnum() or c in "_-.":
                    delim.append(c)
                    i += 1
                    continue
                break
            if delim:
                out.append(("".join(delim), strip))
            continue
        i += 1
    return out


def _strip_comment(line, quote_in):
    """Return (code, quote_out, ends_with_continuation).

    `quote_in` is the quote character still open from the previous physical
    line, or "". A `#` starts a comment only outside quotes and only at the
    start of a word -- `foo#bar` is one word, not a command and a comment.
    """
    out = []
    quote = quote_in
    i = 0
    n = len(line)
    prev = " "
    while i < n:
        ch = line[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < n:
                out.append(ch)
                out.append(line[i + 1])
                i += 2
                continue
            out.append(ch)
            if ch == quote:
                quote = ""
            i += 1
            prev = ch
            continue
        if ch == "\\":
            out.append(ch)
            if i + 1 < n:
                out.append(line[i + 1])
                i += 2
                prev = "\\"
                continue
            # A trailing backslash: this line continues.
            return ("".join(out[:-1]), quote, True)
        if ch == "#" and prev in " \t;&|":
            # Only at the start of a word. `${#a[@]}`, `$#` and `foo#bar` are
            # not comments, and treating them as one truncated the line and
            # hid whatever followed -- which is a gate that passes because it
            # stopped looking.
            break
        if ch in "'\"":
            quote = ch
        out.append(ch)
        prev = ch
        i += 1
    return ("".join(out), quote, False)


def blank_quotes(text, only=None):
    """Empty the interior of every quoted string, keeping the quotes.

    `only` restricts the emptying to one quote character.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\\":
            out.append(ch)
            if i + 1 < n:
                out.append(text[i + 1])
            i += 2
            continue
        if ch in "'\"":
            out.append(ch)
            i += 1
            kept = []
            while i < n:
                if ch == '"' and text[i] == "\\" and i + 1 < n:
                    kept.append(text[i])
                    kept.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == ch:
                    break
                kept.append(text[i])
                i += 1
            if only is not None and ch != only:
                out.extend(kept)
            out.append(ch)
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def lex_shell(lines, blank=False, blank_only=None):
    records = []
    i = 0
    n = len(lines)
    while i < n:
        start = i + 1
        quote = ""
        parts = []
        while True:
            if i >= n:
                break
            code, quote, cont = _strip_comment(lines[i], quote)
            parts.append(code)
            i += 1
            if quote:
                # An unterminated quote: the string runs into the next line.
                continue
            if cont:
                continue
            break
        logical = " ".join(p.strip() for p in parts if p.strip())
        # The here-document delimiter is read from the UNBLANKED line: in
        # `cat <<'''EOF'''` the delimiter is quoted, and blanking it first
        # loses the here-document entirely -- which silently turned a help
        # text into executable code the first time this ran.
        opened = _heredoc_delims(logical)
        if blank:
            logical = blank_quotes(logical, blank_only)
        if logical:
            _emit(records, start, "code", logical)
        # Here-document bodies belong to the logical line that opened them.
        for delim, strip in opened:
            while i < n:
                probe = lines[i]
                candidate = probe.lstrip("\t") if strip else probe
                i += 1
                if candidate.rstrip("\r") == delim:
                    break
                _emit(records, i, "heredoc", probe)
    return records


def lex_md(lines):
    records = []
    fence = ""
    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        if fence:
            if stripped.startswith(fence):
                fence = ""
                _emit(records, index, "prose", line)
                continue
            _emit(records, index, "code", line)
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = stripped[:3]
            _emit(records, index, "prose", line)
            continue
        _emit(records, index, "prose", line)
    return records


def lex_yaml(lines):
    records = []
    shell_indent = None
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            _emit(records, index, "prose", line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if shell_indent is not None and indent > shell_indent:
            _emit(records, index, "code", line)
            continue
        shell_indent = None
        body = line.lstrip(" ").lstrip("-").lstrip(" ")
        key = body.split(":", 1)[0].strip()
        if key in _YAML_SHELL_KEYS and ":" in body:
            shell_indent = indent
            _emit(records, index, "code", body.split(":", 1)[1])
            continue
        _emit(records, index, "prose", line)
    return records


def lex_raw(lines):
    records = []
    for index, line in enumerate(lines, start=1):
        _emit(records, index, "code", line)
    return records


def main(argv):
    if len(argv) != 3 or argv[1] not in _SHELL_MODES:
        sys.stderr.write(
            "usage: python3 tests/gate-strip.py {%s} PATH\n" % "|".join(_SHELL_MODES)
        )
        return 2
    mode, path = argv[1], argv[2]
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("gate-strip.py: %s: %s\n" % (path, exc.strerror))
        return 2
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if mode == "shellq":
        records = lex_shell(lines, blank=True)
    elif mode == "shellq1":
        records = lex_shell(lines, blank=True, blank_only="'")
    else:
        records = {"shell": lex_shell, "md": lex_md,
                   "yaml": lex_yaml, "raw": lex_raw}[mode](lines)
    sys.stdout.write("\n".join(records))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
