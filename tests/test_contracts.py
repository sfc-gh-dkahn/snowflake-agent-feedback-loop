"""Offline source contracts, not a Snowflake parser, compiler, or live test runner.

Run: python3 -B -m unittest discover -s tests -p 'test_contracts.py' -v
Only repository SQL text is read. No credentials, network, subprocesses, or packages.
The lexer handles comments, escaped strings, quoted identifiers and dollar bodies;
the small structural readers support this repository's CREATE/SELECT/JSON forms.
Unsupported forms fail explicitly rather than pretending to compile Snowflake SQL.
SQL fixtures/assertions must be run separately, later, in a disposable installation.
"""

import ast
import json
import re
import unittest
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTEXT = "USE DATABASE __OUTPUT_DATABASE__; USE SCHEMA __OUTPUT_SCHEMA__;"
IDENTITY = "agent_database agent_schema agent_name"
DIAGNOSIS_FIELDS = (
    "assessment issue_type severity surface observation evidence_quote "
    "suspected_cause preserve_behavior requires_review"
).split()
RECOMMENDATION_FIELDS = (
    "recommendation_warranted headline reasoning suggested_change change_mode "
    "displaced_text preserve_behavior would_regress_good_behavior confidence citations"
).split()
TABLE_FIELDS = {
    "AF_CONFIG": "config_id " + IDENTITY + " judge_model docs_service lookback_days max_diagnoses max_recommendations min_occurrences docs_cache_hours prompt_revision",
    "AF_RUNS": "run_id started_at completed_at window_start window_end thread_filter status stage diagnostics error_message",
    "AF_CONFIG_SNAPSHOTS": "run_id " + IDENTITY + " captured_at config_hash agent_spec",
    "AF_EVENTS": "event_hash " + IDENTITY + " event_ts trace_id span_id span_name span_type thread_id message_id user_message agent_response tool_name final_sql chart_spec status_code first_seen_at",
    "AF_RUN_FEEDBACK": "run_id diagnosis_id " + IDENTITY + " thread_id response_trace_id feedback_trace_id feedback_ts evidence current_config config_hash judge_model prompt_revision",
    "AF_DIAGNOSES": "diagnosis_id created_at raw_output validation_status error_message",
    "AF_SUPPORTED_AREAS": "surface retrieval_query",
    "AF_DOC_CACHE": "service_name surface query_hash retrieved_at content_hash passages",
    "AF_RECOMMENDATIONS": "recommendation_id run_id " + IDENTITY + " surface evidence docs docs_status created_at raw_output review_status error_message",
    "AF_RUN_RECOMMENDATIONS": "run_id recommendation_id",
    "AF_DELIVERY": "delivery_id run_id payload_hash integration_name recipient status claimed_at completed_at error_message",
}
TURN_FIELDS = (IDENTITY + " thread_id trace_id message_id event_ts root_event_hash user_message agent_response status_code tool_evidence event_hashes is_complete turn_no turn_hash").split()
VIEW_FIELDS = {
    "AF_TURNS": TURN_FIELDS,
    "AF_FEEDBACK_PAIRS": TURN_FIELDS + ["response_trace_id", "response_turn_hash"],
    "AF_FINDINGS": ("run_id diagnosis_id " + IDENTITY + " thread_id response_trace_id feedback_trace_id feedback_ts judged_at validation_status assessment issue_type surface severity observation suspected_cause preserve_behavior error_message review_status").split(),
    "AF_REVIEW_QUEUE": ("run_id recommendation_id " + IDENTITY + " surface created_at summary reasoning suggested_change change_mode displaced_text preserve_behavior confidence citations review_status docs_status run_status completed_at").split(),
}
TASK_PARENTS = {
    "AF_START": None,
    "AF_CAPTURE": "AF_START",
    "AF_PREPARE": "AF_CAPTURE",
    "AF_DIAGNOSE": "AF_PREPARE",
    "AF_RECOMMEND": "AF_DIAGNOSE",
    "AF_FINISH": "AF_RECOMMEND",
}
TASK_CALLS = {
    "AF_START": "AF_START_RUN",
    "AF_CAPTURE": "AF_CAPTURE_CONTEXT",
    "AF_PREPARE": "AF_PREPARE_FEEDBACK",
    "AF_DIAGNOSE": "AF_DIAGNOSE",
    "AF_RECOMMEND": "AF_RECOMMEND",
    "AF_FINISH": "AF_FINISH",
}


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


def code(tokens):
    return " ".join(token.value.upper() if token.kind == "word" else token.value
                    for token in tokens if token.kind not in {"string", "dollar"})


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


def nested_tokens(tokens):
    for token in tokens:
        if token.kind == "dollar":
            yield from nested_tokens(lex(token.value))
        else:
            yield token


def check_delimiters(tokens):
    stack = []
    closing = {")": "(", "]": "[", "}": "{"}
    for token in tokens:
        if token.kind == "dollar":
            check_delimiters(lex(token.value))
        elif token.kind == "symbol":
            if token.value in closing.values():
                stack.append(token.value)
            elif token.value in closing:
                if not stack or stack.pop() != closing[token.value]:
                    raise ValueError(f"Mismatched delimiter at offset {token.offset}")
    if stack:
        raise ValueError("Unclosed expression delimiter")


def grouped(tokens, start, opening="(", closing=")"):
    if tokens[start].value != opening:
        raise ValueError(f"Expected {opening} at {tokens[start].offset}")
    depth = 0
    for cursor in range(start, len(tokens)):
        token = tokens[cursor]
        if token.kind != "symbol":
            continue
        if token.value == opening:
            depth += 1
        elif token.value == closing:
            depth -= 1
            if depth == 0:
                return tokens[start + 1:cursor], cursor + 1
    raise ValueError(f"Unclosed {opening} at {tokens[start].offset}")


def comma_parts(tokens):
    parts = [[]]
    depth = 0
    for token in tokens:
        if token.kind == "symbol":
            if token.value in {"(", "[", "{"}:
                depth += 1
            elif token.value in {")", "]", "}"}:
                depth -= 1
            elif token.value == "," and depth == 0:
                parts.append([])
                continue
        parts[-1].append(token)
    return parts


def projection(tokens):
    depth = 0
    start = None
    for cursor, token in enumerate(tokens):
        if token.kind == "symbol":
            depth += token.value == "("
            depth -= token.value == ")"
        if depth == 0 and token.kind == "word":
            if token.value.upper() == "SELECT":
                start = cursor + 1
            elif token.value.upper() == "FROM" and start is not None:
                fields = []
                for part in comma_parts(tokens[start:cursor]):
                    if values(part) == ["FEEDBACK", ".", "*"]:
                        fields.extend(TURN_FIELDS)
                    elif part[-1].kind in {"word", "identifier"}:
                        fields.append(part[-1].value.lower())
                    else:
                        raise ValueError("Unsupported SELECT projection; provide an explicit alias")
                return fields
    raise ValueError("No supported top-level SELECT/FROM")


def object_literal(tokens):
    """Parse literal response-schema objects, never SQL expressions or executable code."""
    rendered = " ".join(repr(token.value) if token.kind == "string"
                        else {"FALSE": "False", "TRUE": "True", "NULL": "None"}.get(token.value.upper(), token.value)
                        for token in tokens)
    return ast.literal_eval(rendered)


def ai_calls(tokens):
    flat = list(nested_tokens(tokens))
    for cursor, token in enumerate(flat[:-1]):
        if token.kind == "word" and (token.value.upper().startswith("AI_") or token.value.upper() == "COMPLETE"):
            if flat[cursor + 1].value == "(":
                yield token.value.upper(), grouped(flat, cursor + 1)[0]


class LexerTests(unittest.TestCase):
    def test_qualified_identifier_lexing_preserves_quotes_and_offsets(self):
        source = 'db /* separator */ . "schema.with.dot" . "AF_""Mixed;Name"'
        tokens = lex(source)
        self.assertEqual([(token.kind, token.value) for token in tokens], [
            ("word", "db"), ("symbol", "."), ("identifier", "schema.with.dot"),
            ("symbol", "."), ("identifier", 'AF_"Mixed;Name'),
        ])
        self.assertEqual([source[token.offset] for token in tokens], ['d', '.', '"', '.', '"'])
        self.assertEqual(qualified_identifier(tokens, 0), (["DB", "schema.with.dot", 'AF_"Mixed;Name'], 5))

    def test_qualified_definitions_keep_terminal_names_and_body_cursor(self):
        for prefix, kind in [
            ("CREATE PROCEDURE", "PROCEDURE"),
            ("CREATE OR REPLACE FUNCTION", "FUNCTION"),
            ("CREATE TABLE IF NOT EXISTS", "TABLE"),
            ("CREATE TEMPORARY TABLE", "TABLE"),
        ]:
            for name in ["af_example", "schema.af_example", "__OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.af_example"]:
                with self.subTest(prefix=prefix, name=name):
                    tokens = lex(f"{prefix} {name}(argument VARCHAR);")
                    actual_kind, actual_name, cursor = definition(tokens)
                    self.assertEqual((actual_kind, actual_name), (kind, "AF_EXAMPLE"))
                    self.assertEqual(values(tokens[cursor:]), ["(", "ARGUMENT", "VARCHAR", ")", ";"])

    def test_quoted_definition_names_are_not_split_or_uppercased(self):
        for name, expected in [
            ('"AF_Mixed"', "AF_Mixed"),
            ('"db.with.dot"."schema"."AF_""Mixed;Name"', 'AF_"Mixed;Name'),
            ('db."schema"."AF_Name.With.Dot"', "AF_Name.With.Dot"),
            ('"db" /* . ignored */ . schema . "AF_Name"', "AF_Name"),
        ]:
            with self.subTest(name=name):
                chunks = statements(f"CREATE VIEW {name} AS SELECT field FROM source;")
                self.assertEqual(len(chunks), 1)
                kind, actual_name, cursor = definition(chunks[0])
                self.assertEqual((kind, actual_name), ("VIEW", expected))
                self.assertEqual(values(chunks[0][cursor:cursor + 2]), ["AS", "SELECT"])
        self.assertIsNone(definition(lex('"CREATE" TABLE AF_X (field VARCHAR);')))

    def test_qualified_definitions_have_distinct_terminal_keys(self):
        chunks = statements(
            "CREATE PROCEDURE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_FIRST() RETURNS VARCHAR LANGUAGE SQL AS $$BEGIN RETURN 'first'; END;$$;"
            "CREATE PROCEDURE __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_SECOND() RETURNS VARCHAR LANGUAGE SQL AS $$BEGIN RETURN 'second'; END;$$;"
        )
        self.assertEqual([definition(chunk)[:2] for chunk in chunks], [
            ("PROCEDURE", "AF_FIRST"), ("PROCEDURE", "AF_SECOND"),
        ])

    def test_malformed_definition_identifiers_fail_explicitly(self):
        for source in ["CREATE", "CREATE OR REPLACE", "CREATE TABLE", "CREATE TABLE IF NOT EXISTS",
                       "CREATE TABLE db.", "CREATE TABLE db..AF_X (field VARCHAR);",
                       "CREATE TABLE db.'schema'.AF_X (field VARCHAR);",
                       "CREATE TABLE db.schema.123 (field VARCHAR);",
                       'CREATE TABLE db."".AF_X (field VARCHAR);',
                       "CREATE TABLE db.schema.AF_X.extra (field VARCHAR);"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                definition(lex(source))

    def test_quotes_comments_dollar_and_semicolons(self):
        source = "-- $$ ;\nSELECT '$$;it''s', 'escaped\\\'quote', \"a;\"\"b\"; /* $$ /* ; */ */ SELECT $$literal;payload$$;"
        self.assertEqual(len(statements(source)), 2)
        self.assertEqual([token.value for token in lex(source) if token.kind == "string"], ["$$;it's", "escaped'quote"])

    def test_unclosed_lexical_constructs_fail(self):
        for source in ["SELECT $$oops;", "SELECT 'oops;", 'SELECT "oops;', "/* oops", "SELECT 'oops\\"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                lex(source)

    def test_even_dollar_count_is_not_balance(self):
        with self.assertRaises(ValueError):
            lex("SELECT '$$'; SELECT $$unclosed")
        self.assertEqual(len(lex("SELECT '$$'; -- $$\n")), 3)

    def test_task_body_is_one_statement(self):
        for name in ["AF_X", "__OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_X", '"db.name"."schema"."AF_X"']:
            with self.subTest(name=name):
                source = f"CREATE TASK {name} AS DECLARE flag BOOLEAN; BEGIN IF (flag) THEN SELECT ';'; END IF; BEGIN SELECT 1; END; END; SELECT 2;"
                chunks = statements(source)
                self.assertEqual(len(chunks), 2)
                self.assertEqual(definition(chunks[0])[:2], ("TASK", "AF_X"))
        with self.assertRaises(ValueError):
            statements("CREATE TASK AF_X AS DECLARE flag BOOLEAN; BEGIN SELECT 1;")

    def test_dollar_body_is_scanned_for_ai(self):
        source = "CREATE PROCEDURE AF_X() RETURNS VARIANT LANGUAGE SQL AS $$ BEGIN SELECT AI_COMPLETE(model => :model); END; $$;"
        self.assertEqual([name for name, _ in ai_calls(lex(source))], ["AI_COMPLETE"])
        self.assertEqual(list(ai_calls(lex("SELECT 'AI_COMPLETE(model => 1)';"))), [])

    def test_grouping_ignores_punctuation_in_strings(self):
        tokens = lex("(first NUMBER(10, 2), second VARCHAR DEFAULT '),;')")
        inside, end = grouped(tokens, 0)
        self.assertEqual(end, len(tokens))
        self.assertEqual(len(comma_parts(inside)), 2)

    def test_expression_delimiters_and_dollar_scope(self):
        check_delimiters(lex("SELECT ARRAY_CONSTRUCT(')', {'key': [1, 2]});"))
        for source in ["SELECT ([)];", "SELECT (1;", "SELECT $$SELECT (1;$$;", "SELECT )1(;"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                check_delimiters(lex(source))


class SourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Only the repository's own SQL directories. A recursive sweep would also
        # read rendered copies under the gitignored local/, results/, and logs/
        # directories, and report every object in them as a duplicate definition.
        cls.paths = sorted(
            path
            for directory in ("sql", "tests", "optional")
            for path in (ROOT / directory).glob("*.sql")
        )
        cls.sources = {path.relative_to(ROOT).as_posix(): path.read_text(encoding="utf-8") for path in cls.paths}
        cls.parsed = {name: statements(source) for name, source in cls.sources.items()}
        cls.definitions = {}
        for name, chunks in cls.parsed.items():
            for chunk in chunks:
                info = definition(chunk)
                if info:
                    kind, object_name, _ = info
                    key = (kind, object_name)
                    if key in cls.definitions:
                        raise AssertionError(f"Duplicate definition {key}: {name}")
                    cls.definitions[key] = chunk

    def test_all_public_sql_has_explicit_output_context(self):
        self.assertTrue(self.sources)
        expected = [values(chunk) for chunk in statements(CONTEXT)]
        for name, chunks in self.parsed.items():
            with self.subTest(file=name):
                self.assertEqual([values(chunk) for chunk in chunks[:2]], expected)
                flat = list(nested_tokens([token for chunk in chunks for token in chunk]))
                context_words = [token.value.upper() for token in flat if token.kind == "word"]
                self.assertNotIn("PUBLIC", context_words)
                uses = [chunk for chunk in chunks if values(chunk)[:1] == ["USE"]]
                self.assertEqual(len(uses), 2, "Unexpected context switch")

    def test_placeholder_allowlist_and_rendered_scan(self):
        common = {"__OUTPUT_DATABASE__", "__OUTPUT_SCHEMA__"}
        allowed_by_file = {
            "sql/00_setup.sql": common | {"__AGENT_DATABASE__", "__AGENT_SCHEMA__", "__AGENT_NAME__", "__JUDGE_MODEL__"},
            "sql/06_tasks.sql": common | {"__WAREHOUSE__"},
        }
        for name, source in self.sources.items():
            with self.subTest(file=name):
                found = set(re.findall(r"__[A-Za-z][A-Za-z0-9_]*?__", source))
                self.assertEqual(found, allowed_by_file.get(name, common))
                rendered = source
                for placeholder in found:
                    rendered = rendered.replace(placeholder, "AF_RENDER_SYNTHETIC")
                self.assertIsNone(re.search(r"__[A-Za-z][A-Za-z0-9_]*?__", rendered))
                self.assertIsNone(re.search(r"\b(?:TODO|FIXME|CHANGEME)\b", source, re.I))
                statements(rendered)

    def test_every_dollar_sql_body_lexes_and_ends(self):
        for name, chunks in self.parsed.items():
            for chunk in chunks:
                with self.subTest(file=name, offset=chunk[0].offset):
                    check_delimiters(chunk)
                for token in chunk:
                    if token.kind == "dollar":
                        with self.subTest(file=name, offset=token.offset):
                            body = lex(token.value)
                            self.assertTrue(body)
                            info = definition(chunk)
                            if info and info[0] == "FUNCTION":
                                self.assertNotIn(";", values(body))
                            else:
                                self.assertEqual(values(body)[-2:], ["END", ";"])

    def test_install_has_no_runtime_statements(self):
        for name, chunks in self.parsed.items():
            if name.startswith("tests/"):
                continue
            for chunk in chunks:
                with self.subTest(file=name, offset=chunk[0].offset):
                    self.assertIn(values(chunk)[0], {"USE", "CREATE", "INSERT"})
                    if values(chunk)[0] == "INSERT":
                        self.assertIn(values(chunk)[2], {"AF_CONFIG", "AF_SUPPORTED_AREAS"})

    def test_no_schedule_resume_or_task_execution(self):
        forbidden = r"\bSCHEDULE\s*=|\bALTER\s+TASK\b[\s\S]*?\bRESUME\b|\bEXECUTE\s+TASK\b|\bSYSTEM\$TASK_DEPENDENTS_ENABLE\s*\("
        for name, chunks in self.parsed.items():
            with self.subTest(file=name):
                flat = list(nested_tokens([token for chunk in chunks for token in chunk]))
                self.assertNotRegex(code(flat), forbidden)
                for token in flat:
                    if token.kind == "string" and re.match(r"\s*(ALTER|EXECUTE|SELECT|CALL)\b", token.value, re.I):
                        self.assertNotRegex(token.value.upper(), forbidden)

    def test_exact_task_graph_and_return_value_flow(self):
        tasks = {name: chunk for (kind, name), chunk in self.definitions.items() if kind == "TASK"}
        self.assertEqual(set(tasks), set(TASK_PARENTS) | {"AF_FINALIZE"})
        for name, parent in TASK_PARENTS.items():
            with self.subTest(task=name):
                task = tasks[name]
                words = values(task)
                header = words[:words.index("AS")]
                self.assertIn("__WAREHOUSE__", header)
                if parent:
                    self.assertEqual(header[header.index("AFTER") + 1:], [parent])
                    predecessor = words.index("SYSTEM$GET_PREDECESSOR_RETURN_VALUE")
                    arguments, _ = grouped(task, predecessor + 1)
                    self.assertEqual([(token.kind, token.value) for token in arguments], [("string", parent)])
                else:
                    self.assertNotIn("AFTER", header)
                    self.assertIn("OVERLAP_POLICY = NO_OVERLAP", code(task))
                    self.assertIn("TASK_AUTO_RETRY_ATTEMPTS = 0", code(task))
                self.assertRegex(code(task), rf"CALL __OUTPUT_DATABASE__ \. __OUTPUT_SCHEMA__ \. {TASK_CALLS[name]}\s*\(")
                self.assertRegex(code(task), r"CALL SYSTEM\$SET_RETURN_VALUE\s*\( : V_RUN_ID \)")
        self.assertIn("FINALIZE = AF_START", code(tasks["AF_FINALIZE"]))
        self.assertNotIn("AFTER", values(tasks["AF_FINALIZE"]))

    def test_ai_is_only_in_procedures_and_models_are_bound(self):
        found = []
        for name, chunks in self.parsed.items():
            for chunk in chunks:
                info = definition(chunk)
                for function_name, arguments in ai_calls(chunk):
                    with self.subTest(file=name, function=function_name):
                        self.assertIsNotNone(info)
                        self.assertEqual(info[0], "PROCEDURE")
                        found.append(info[1])
                        model = next(part for part in comma_parts(arguments) if values(part)[:2] == ["MODEL", "=>"])
                        self.assertEqual(values(model)[2], ":")
                        self.assertEqual(len(model), 4)
                        self.assertEqual(model[-1].kind, "word")
        self.assertCountEqual(found, ["AF_DIAGNOSE", "AF_RECOMMEND"])
        for name, source in self.sources.items():
            with self.subTest(file=name):
                self.assertNotRegex(source, r"[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
        setup = self.parsed["sql/00_setup.sql"]
        config = next(chunk for chunk in setup if values(chunk)[:3] == ["INSERT", "INTO", "AF_CONFIG"])
        config_values, _ = grouped(config, values(config).index("VALUES") + 1)
        fields = comma_parts(config_values)
        self.assertEqual([part[0].value for part in fields[1:5]], ["__AGENT_DATABASE__", "__AGENT_SCHEMA__", "__AGENT_NAME__", "__JUDGE_MODEL__"])
        self.assertEqual(values(fields[5]), ["NULL"])
        email = code(list(nested_tokens(self.definitions[("PROCEDURE", "AF_SEND_EMAIL")])))
        self.assertIn("CALL SYSTEM$SEND_EMAIL ( : P_INTEGRATION , : V_RECIPIENT ,", email)
        self.assertIn("V_RECIPIENT := LOWER ( P_RECIPIENT )", email)
        diagnose = code(list(nested_tokens(self.definitions[("PROCEDURE", "AF_DIAGNOSE")])))
        self.assertIn("MODEL_NAME := CANDIDATE . JUDGE_MODEL", diagnose)

    def test_no_autonomous_agent_mutations(self):
        pattern = r"\b(?:ALTER|DROP)\s+AGENT\b|\bCREATE\s+(?:OR\s+REPLACE\s+)?AGENT\b|\bGRANT\b|\bREVOKE\b"
        for name, chunks in self.parsed.items():
            flat = list(nested_tokens([token for chunk in chunks for token in chunk]))
            with self.subTest(file=name):
                self.assertNotRegex(code(flat), pattern)
                for token in flat:
                    if token.kind == "string" and re.match(r"\s*(ALTER|CREATE|DROP|GRANT|REVOKE)\b", token.value, re.I):
                        self.assertNotRegex(token.value.upper(), pattern)
        recommend = code(list(nested_tokens(self.definitions[("PROCEDURE", "AF_RECOMMEND")])))
        self.assertNotIn("EXECUTE IMMEDIATE : OUTPUT", recommend)
        self.assertNotIn("EXECUTE IMMEDIATE : SUGGESTED_CHANGE", recommend)

    def test_docs_source_columns_and_configured_service(self):
        body = list(nested_tokens(self.definitions[("PROCEDURE", "AF_RECOMMEND")]))
        words = values(body)
        arrays = []
        for cursor, token in enumerate(body[:-1]):
            if token.kind == "word" and token.value.upper() == "ARRAY_CONSTRUCT" and body[cursor + 1].value == "(":
                arguments, _ = grouped(body, cursor + 1)
                arrays.append([part[0].value for part in comma_parts(arguments) if len(part) == 1 and part[0].kind == "string"])
        self.assertIn(["SOURCE_URL", "DOCUMENT_TITLE", "CHUNK"], arrays)
        self.assertIn("source_url", words)
        self.assertIn("document_title", words)
        self.assertIn("chunk", words)
        source = self.sources["sql/05_recommend.sql"]
        self.assertRegex(source, r"GET_IGNORE_CASE\(doc\.value, 'source_url'\)")
        self.assertRegex(source, r"SEARCH_PREVIEW\('[^\n]*\|\| docs_service")
        self.assertIn("https://docs.snowflake.com/", [token.value for token in body if token.kind == "string"])
        self.assertIn("'columns', ARRAY_CONSTRUCT('SOURCE_URL', 'DOCUMENT_TITLE', 'CHUNK')", source)

    def test_exact_table_and_view_field_lists(self):
        tables = {name: chunk for (kind, name), chunk in self.definitions.items() if kind == "TABLE" and name != "AF_FIXTURE_EVENTS"}
        self.assertEqual(set(tables), set(TABLE_FIELDS))
        for name, expected in TABLE_FIELDS.items():
            with self.subTest(table=name):
                chunk = tables[name]
                fields, _ = grouped(chunk, definition(chunk)[2])
                self.assertEqual([part[0].value.lower() for part in comma_parts(fields)], expected.split())
        views = {name: chunk for (kind, name), chunk in self.definitions.items() if kind == "VIEW"}
        self.assertEqual(set(views), set(VIEW_FIELDS))
        for name, expected in VIEW_FIELDS.items():
            with self.subTest(view=name):
                self.assertEqual(projection(views[name]), expected)

    def test_cached_diagnoses_do_not_spend_the_new_pair_cap(self):
        body = list(nested_tokens(self.definitions[("PROCEDURE", "AF_PREPARE_FEEDBACK")]))
        words = values(body)
        ctes = {}
        for name in ["PAIRS", "SELECTED"]:
            positions = [index for index in range(len(words)) if words[index:index + 3] == [name, "AS", "("]]
            self.assertEqual(len(positions), 1)
            ctes[name], _ = grouped(body, positions[0] + 2)
        for forbidden in ["LIMIT", "QUALIFY", "ROW_NUMBER", "V_LIMIT"]:
            self.assertNotIn(forbidden, values(ctes["PAIRS"]), "Do not cap pairs before checking cached identities")
        expected = lex(
            "SELECT identities.*, persisted.diagnosis_id IS NOT NULL AS is_cached "
            "FROM identities "
            "LEFT JOIN (SELECT DISTINCT diagnosis_id FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSES) AS persisted "
            "ON persisted.diagnosis_id = identities.diagnosis_id "
            "QUALIFY is_cached OR ROW_NUMBER() OVER ("
            "PARTITION BY is_cached ORDER BY event_ts DESC, trace_id, response_trace_id) <= :V_LIMIT"
        )
        self.assertEqual(values(ctes["SELECTED"]), values(expected))
        self.assertIn("V_LIMIT := V_CONFIG : MAX_DIAGNOSES :: INTEGER", code(body))
        self.assertIn("FROM SELECTED AS PAIRS LEFT JOIN CACHED_EVIDENCE", code(body))
        diagnose = list(nested_tokens(self.definitions[("PROCEDURE", "AF_DIAGNOSE")]))
        candidate_start = values(diagnose).index("CANDIDATES", values(diagnose).index("BEGIN"))
        candidates, _ = grouped(diagnose, candidate_start + 2)
        self.assertEqual(values(candidates), values(lex(
            "SELECT feedback.* FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_RUN_FEEDBACK AS feedback "
            "WHERE feedback.run_id = :P_RUN_ID AND NOT EXISTS ("
            "SELECT 1 FROM __OUTPUT_DATABASE__.__OUTPUT_SCHEMA__.AF_DIAGNOSES AS previous "
            "WHERE previous.diagnosis_id = feedback.diagnosis_id) "
            "ORDER BY feedback.feedback_ts, feedback.diagnosis_id"
        )))

    def test_response_schema_fields_match_validators_and_mocks(self):
        diagnosis = list(nested_tokens(self.definitions[("PROCEDURE", "AF_DIAGNOSE")]))
        cursor = next(index for index, token in enumerate(diagnosis) if token.value.lower() == "response_format")
        content, _ = grouped(diagnosis, cursor + 2, "{", "}")
        diagnosis_schema = object_literal([Token("symbol", "{", 0)] + content + [Token("symbol", "}", 0)])["schema"]
        recommendation = list(nested_tokens(self.definitions[("PROCEDURE", "AF_RECOMMEND")]))
        schema_text = next(token.value for token in recommendation if token.kind == "string" and token.value.lstrip().startswith('{\n        "type": "json"'))
        recommendation_schema = json.loads(schema_text)["schema"]
        assertion_strings = [token.value for token in nested_tokens(lex(self.sources["tests/assertions.sql"])) if token.kind == "string"]
        for kind, schema, fields, validator in [
            ("diagnosis", diagnosis_schema, DIAGNOSIS_FIELDS, "AF_DIAGNOSIS_VALID"),
            ("recommendation", recommendation_schema, RECOMMENDATION_FIELDS, "AF_RECOMMENDATION_VALID"),
        ]:
            with self.subTest(kind=kind):
                self.assertEqual(set(schema["properties"]), set(fields))
                self.assertCountEqual(schema["required"], fields)
                body = code(list(nested_tokens(self.definitions[("FUNCTION", validator)])))
                referenced = set(re.findall(r"\bRESULT : ([A-Z_]+)", body))
                self.assertEqual(referenced, {field.upper() for field in fields})
                mocks = [json.loads(text) for text in assertion_strings if text.startswith('{"assessment":') or text.startswith('{"recommendation_warranted":')]
                matching = [mock for mock in mocks if set(mock) == set(fields)]
                self.assertEqual(len(matching), 1)
        self.assertFalse(recommendation_schema["additionalProperties"])
        citations = recommendation_schema["properties"]["citations"]["items"]
        self.assertEqual(set(citations["properties"]), {"url", "quote", "supports"})
        self.assertCountEqual(citations["required"], ["url", "quote", "supports"])

    def test_fixture_insert_covers_every_event_field(self):
        flat = list(nested_tokens(lex(self.sources["tests/fixtures.sql"])))
        words = values(flat)
        cursor = next(index for index in range(len(words)) if words[index:index + 3] == ["INSERT", "INTO", "AF_EVENTS"])
        fields, end = grouped(flat, cursor + 3)
        expected = TABLE_FIELDS["AF_EVENTS"].split()
        self.assertEqual([part[0].value.lower() for part in comma_parts(fields)], expected)
        self.assertEqual(projection(flat[end:]), expected)
        table = self.definitions[("TABLE", "AF_EVENTS")]
        columns, _ = grouped(table, definition(table)[2])
        required = [part[0].value.lower() for part in comma_parts(columns) if "NOT NULL" in code(part)]
        self.assertIn("first_seen_at", required)
        self.assertTrue(set(required).issubset(expected))

    def test_fixture_safety_transaction_and_rollback(self):
        fixtures = self.parsed["tests/fixtures.sql"]
        start = next(index for index, chunk in enumerate(fixtures) if values(chunk) == ["BEGIN", "TRANSACTION", ";"])
        self.assertEqual(start, len(fixtures) - 2)
        guard = list(nested_tokens(fixtures[2]))
        self.assertIn("CURRENT_TRANSACTION ( ) IS NOT NULL", code(guard))
        self.assertIn("EXISTING_ROWS <> 0", code(guard))
        self.assertIn("CURRENT_SCHEMA ( ) <>", code(guard))
        guard_strings = [token.value for token in guard if token.kind == "string"]
        self.assertIn("__OUTPUT_SCHEMA__", guard_strings)
        self.assertNotIn("AF_TEST_", guard_strings)
        self.assertIn("TASK_COUNT <> 7 OR UNSAFE_TASKS <> 0", code(guard))
        self.assertIn("SUSPENDED", [token.value for token in guard if token.kind == "string"])
        for name in ["tests/fixtures.sql", "tests/assertions.sql"]:
            flat = list(nested_tokens(lex(self.sources[name])))
            with self.subTest(file=name):
                self.assertNotIn("COMMIT", values(flat))
                self.assertNotIn("CALL", values(flat))
                self.assertEqual(list(ai_calls(flat)), [])
                self.assertNotIn("GET_AI_OBSERVABILITY_EVENTS", values(flat))
                self.assertNotIn("SEARCH_PREVIEW", values(flat))
        transaction = code(list(nested_tokens([token for chunk in fixtures[start:] for token in chunk])))
        self.assertNotRegex(transaction, r"\b(?:CREATE|ALTER|DROP|TRUNCATE)\b")
        self.assertIn("FIXTURE_TRANSACTION_ID = CURRENT_TRANSACTION ( )", transaction)
        assertions = code(list(nested_tokens(lex(self.sources["tests/assertions.sql"]))))
        self.assertNotRegex(assertions, r"\b(?:CREATE|ALTER|DROP|TRUNCATE|INSERT|UPDATE|DELETE)\b")
        self.assertIn("FIXTURE_TRANSACTION = CURRENT_TRANSACTION ( )", assertions)
        self.assertIn("REMAINING_EVENTS <> 0", assertions)
        self.assertIn("RAISE ASSERTION_FAILED", assertions)
        # Transaction control must sit at session scope: Snowflake rejects a
        # scripting block that rolls back a transaction begun outside it.
        for name in ["tests/fixtures.sql", "tests/assertions.sql"]:
            with self.subTest(file=name):
                for chunk in self.parsed[name]:
                    for token in chunk:
                        if token.kind == "dollar":
                            self.assertNotIn("ROLLBACK", values(lex(token.value)))
        top_level = [values(chunk) for chunk in self.parsed["tests/assertions.sql"]]
        self.assertEqual(top_level.count(["ROLLBACK", ";"]), 1)

    def test_fixture_population_is_explicit_and_synthetic(self):
        table = self.definitions[("TABLE", "AF_FIXTURE_EVENTS")]
        words = values(table)
        counts = {}
        rows_by_cte = {}
        for name in ["IDENTITIES", "ROOTS", "TOOLS"]:
            cursor = next(index for index in range(len(words)) if words[index:index + 3] == [name, "AS", "("])
            body, _ = grouped(table, cursor + 2)
            value_index = values(body).index("VALUES")
            rows = comma_parts(body[value_index + 1:])
            rows_by_cte[name] = [[part[0].value for part in comma_parts(grouped(row, 0)[0])] for row in rows]
            counts[name] = len(rows)
        self.assertEqual(counts, {"IDENTITIES": 4, "ROOTS": 23, "TOOLS": 7})
        self.assertEqual(counts["IDENTITIES"] * (counts["ROOTS"] + counts["TOOLS"]), 120)
        for row in rows_by_cte["IDENTITIES"]:
            self.assertTrue(all(value.startswith("AF_SYNTH_") for value in row))
        for row in rows_by_cte["ROOTS"] + rows_by_cte["TOOLS"]:
            self.assertTrue(row[1].startswith("af_fixture_"))
        self.assertEqual(len({row[1] for row in rows_by_cte["ROOTS"]}), 20)
        self.assertIn("OBJECT_DELETE", self.sources["tests/assertions.sql"])
        self.assertIn("'missing_' || field.key", self.sources["tests/assertions.sql"])
        self.assertIn("'wrong_type_' || field.key", self.sources["tests/assertions.sql"])


if __name__ == "__main__":
    unittest.main()