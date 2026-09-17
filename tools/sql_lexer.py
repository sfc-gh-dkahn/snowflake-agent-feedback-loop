"""Split the SQL forms used by this repository. This is not a SQL compiler."""

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    offset: int


def lex(source):
    """Lex Snowflake's untagged $$ delimiter; quoted/commented $$ is not a body."""
    tokens = []
    cursor = 0
    while cursor < len(source):
        start = cursor
        character = source[cursor]
        if character.isspace():
            cursor += 1
        elif source.startswith("--", cursor):
            end = source.find("\n", cursor)
            cursor = len(source) if end == -1 else end + 1
        elif source.startswith("/*", cursor):
            depth = 1
            cursor += 2
            while cursor < len(source) and depth:
                if source.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            if depth:
                raise ValueError(f"Unterminated block comment at offset {start}")
        elif character in ("'", '"'):
            delimiter = character
            cursor += 1
            content = []
            while cursor < len(source):
                character = source[cursor]
                if character == delimiter:
                    if source.startswith(delimiter * 2, cursor):
                        content.append(delimiter)
                        cursor += 2
                        continue
                    cursor += 1
                    break
                if delimiter == "'" and character == "\\":
                    if cursor + 1 == len(source):
                        raise ValueError(f"Unterminated escape at offset {cursor}")
                    escaped = source[cursor + 1]
                    content.append({"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped))
                    cursor += 2
                else:
                    content.append(character)
                    cursor += 1
            else:
                raise ValueError(f"Unterminated quoted token at offset {start}")
            tokens.append(Token("string" if delimiter == "'" else "identifier", "".join(content), start))
        elif source.startswith("$$", cursor):
            end = source.find("$$", cursor + 2)
            if end == -1:
                raise ValueError(f"Unterminated dollar body at offset {start}")
            tokens.append(Token("dollar", source[cursor + 2:end], start))
            cursor = end + 2
        else:
            match = re.match(r"[A-Za-z_][A-Za-z0-9_$]*|[0-9]+|=>|::|:=|\|\||<>", source[cursor:])
            value = match.group() if match else character
            tokens.append(Token("word" if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", value) else "symbol", value, start))
            cursor += len(value)
    return tokens


def values(tokens):
    return [token.value.upper() if token.kind == "word" else token.value for token in tokens]


def qualified_identifier(tokens, start):
    parts = []
    cursor = start
    while True:
        if cursor >= len(tokens) or tokens[cursor].kind not in {"word", "identifier"} or not tokens[cursor].value:
            raise ValueError(f"Expected identifier at token {cursor}")
        parts.append(values(tokens[cursor:cursor + 1])[0])
        cursor += 1
        if cursor >= len(tokens) or tokens[cursor].kind != "symbol" or tokens[cursor].value != ".":
            return parts, cursor
        if len(parts) == 3:
            raise ValueError("Object identifier has more than three parts")
        cursor += 1


def definition(tokens):
    words = values(tokens)
    if not words or tokens[0].kind != "word" or words[0] != "CREATE":
        return None
    cursor = 1
    if words[cursor:cursor + 2] == ["OR", "REPLACE"]:
        cursor += 2
    if words[cursor:cursor + 1] == ["TEMPORARY"]:
        cursor += 1
    if cursor >= len(tokens) or tokens[cursor].kind != "word":
        raise ValueError("Expected CREATE object kind")
    kind = words[cursor]
    cursor += 1
    if words[cursor:cursor + 3] == ["IF", "NOT", "EXISTS"]:
        cursor += 3
    parts, cursor = qualified_identifier(tokens, cursor)
    return kind, parts[-1], cursor


def statements(source):
    """Split lexical statements, preserving unquoted CREATE TASK scripting bodies."""
    result = []
    current = []
    stack = []
    scripting = False
    after_end = False
    for token in lex(source):
        current.append(token)
        words = values(current)
        if words[:2] == ["CREATE", "TASK"] and token.kind == "word" and words[-1] == "DECLARE":
            scripting = True
        if scripting and token.kind == "word":
            word = words[-1]
            if after_end and word in {"IF", "FOR", "LOOP", "CASE", "WHILE"}:
                after_end = False
            elif word == "END":
                if not stack:
                    raise ValueError(f"Unmatched task END at {token.offset}")
                stack.pop()
                after_end = True
            elif word in {"BEGIN", "IF", "FOR", "CASE", "WHILE", "LOOP"}:
                stack.append(word)
                after_end = False
        if token.kind == "symbol" and token.value == ";":
            if not stack and (not scripting or after_end):
                result.append(current)
                current = []
                scripting = False
            after_end = False
    if stack or current:
        raise ValueError("Unclosed scripting block or missing final statement terminator")
    return result


def statement_source(source, chunk):
    """Return the exact source text of one statement chunk, terminator included.

    Sliced from the original text by token offsets, so the result is byte-exact:
    comments, whitespace, and case survive. Nothing is rewritten.
    """
    if not chunk:
        raise ValueError("Empty statement chunk has no source span")
    first = chunk[0]
    last = chunk[-1]
    return source[first.offset:last.offset + len(last.value)]
