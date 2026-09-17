"""Offline tests for the render harness. No Snowflake, no network, no packages.

Run: python3 -B -m unittest discover -s tests -p 'test_*.py' -v

These check the harness refuses bad input, substitutes every placeholder, keeps
install order, writes only into a gitignored directory, and executes nothing.
They do not prove the rendered SQL compiles or that any grant exists.
"""

import ast
import contextlib
import importlib.util
import io
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HARNESS_PATH = ROOT / "tools" / "render_install.py"


def load_harness():
    spec = importlib.util.spec_from_file_location("render_install", HARNESS_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


harness = load_harness()

GOOD = [
    "--output-database", "OUTDB",
    "--output-schema", "OUTSCHEMA",
    "--agent", "AGENTDB.AGENTSCHEMA.AGENTNAME",
    "--warehouse", "WH",
    "--role", "REVIEWER",
    "--judge-model", "claude-sonnet-4-5",
    "--docs-service", "DOCSDB.SHARED.DOCS_SERVICE",
]


def args_for(action, out, extra=()):
    argv = [action] + GOOD + ["--out", str(out)] + list(extra)
    return harness.build_parser().parse_args(argv)


def quietly(handler, args):
    """Call a harness action without its printed plan reaching test output."""
    with contextlib.redirect_stdout(io.StringIO()):
        return handler(args)


class ValidationTests(unittest.TestCase):
    def test_identifier_accepts_uppercase_forms(self):
        for value in ("A", "_X", "SAMPLE_DATA", "T$1", "A" * 255):
            self.assertEqual(harness.check_identifier(value, "x"), value)

    def test_identifier_refuses_bad_forms(self):
        for value in ("", "lower", "1START", "HAS SPACE", "HAS-DASH", "A" * 256, "A.B"):
            with self.assertRaises(harness.HarnessError):
                harness.check_identifier(value, "x")

    def test_identifier_refuses_double_underscore(self):
        # A value containing '__' would read as an unresolved placeholder.
        with self.assertRaises(harness.HarnessError):
            harness.check_identifier("MY__DB", "x")

    def test_model_syntax(self):
        for value in ("claude-sonnet-4-5", "llama3.3-70b", "a", "9x_y.z-1"):
            self.assertEqual(harness.check_model(value), value)
        for value in ("", "-leading", "has space", "a" * 129):
            with self.assertRaises(harness.HarnessError):
                harness.check_model(value)

    def test_agent_needs_three_valid_parts(self):
        self.assertEqual(harness.check_agent("D.S.N"), ["D", "S", "N"])
        for value in ("D.S", "D.S.N.X", "D..N", "d.s.n", "D.S.N__X"):
            with self.assertRaises(harness.HarnessError):
                harness.check_agent(value)

    def test_docs_service_needs_three_valid_parts(self):
        value = "SNOWFLAKE_DOCUMENTATION.SHARED.CKE_SNOWFLAKE_DOCS_SERVICE"
        self.assertEqual(harness.check_docs_service(value), value)
        for bad in ("A.B", "A.B.C.D", "a.b.c", "A.B.C__D"):
            with self.assertRaises(harness.HarnessError):
                harness.check_docs_service(bad)


class PlaceholderTests(unittest.TestCase):
    def test_every_source_placeholder_is_substituted(self):
        values = {name: "X" + name.strip("_") for name in harness.PLACEHOLDER_NAMES}
        for name in harness.INSTALL_FILES + harness.TEST_FILES:
            rendered = harness.render_text(harness.read_source(name), values)
            self.assertEqual(harness.PLACEHOLDER.findall(rendered), [], name)

    def test_unresolved_placeholder_is_refused(self):
        with self.assertRaises(harness.HarnessError):
            harness.render_text("SELECT __OUTPUT_DATABASE__;", {})

    def test_detector_ignores_literal_double_underscore(self):
        # sql/01_preflight.sql contains CONTAINS(..., '__') on purpose. That is
        # not a placeholder and must not trip the unresolved check.
        text = "AND NOT CONTAINS(V_CONFIG:agent_name::VARCHAR, '__')"
        self.assertEqual(harness.render_text(text, {}), text)

    def test_source_files_carry_no_unknown_placeholder(self):
        known = set(harness.PLACEHOLDER_NAMES)
        for name in harness.INSTALL_FILES + harness.TEST_FILES:
            found = set(harness.PLACEHOLDER.findall(harness.read_source(name)))
            self.assertLessEqual(found, known, name)


class OutputDirectoryTests(unittest.TestCase):
    def test_gitignored_directory_is_accepted(self):
        for raw in ("local/render", "results/x", "logs/y"):
            self.assertTrue(str(harness.private_directory(raw)).startswith(str(ROOT)))

    def test_tracked_or_outside_directory_is_refused(self):
        for raw in ("sql", "tests/out", ".", "/tmp/elsewhere", "../escape"):
            with self.assertRaises(harness.HarnessError):
                harness.private_directory(raw)


class RenderActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.out = Path(self.temp.name) / "local" / "render"
        self.addCleanup(self.temp.cleanup)
        # private_directory() resolves against the repo root, so point the
        # harness at the temporary tree for the duration of each test.
        self.original = harness.ROOT
        harness.ROOT = Path(self.temp.name)
        (harness.ROOT / "sql").mkdir(parents=True)
        (harness.ROOT / "tests").mkdir(parents=True)
        for name in harness.INSTALL_FILES + harness.TEST_FILES:
            source = ROOT / name
            shutil.copyfile(source, harness.ROOT / name)
        self.addCleanup(self.restore)

    def restore(self):
        harness.ROOT = self.original

    def test_render_writes_all_files_and_substitutes(self):
        self.assertEqual(quietly(harness.action_render, args_for("render", self.out)), 0)
        for name in harness.INSTALL_FILES + harness.TEST_FILES:
            text = (self.out / name).read_text(encoding="utf-8")
            self.assertIn("OUTDB", text)
            self.assertEqual(harness.PLACEHOLDER.findall(text), [], name)
        self.assertTrue((self.out / "PLAN.txt").is_file())
        self.assertTrue((self.out / harness.CLI_TASKS).is_file())
        self.assertTrue((self.out / harness.CLI_TEST_PAIR).is_file())

    def test_cli_task_file_wraps_each_task_without_changing_it(self):
        quietly(harness.action_render, args_for("render", self.out))
        original = (self.out / "sql" / "06_tasks.sql").read_text(encoding="utf-8")
        derived = (self.out / harness.CLI_TASKS).read_text(encoding="utf-8")
        self.assertEqual(derived.count("EXECUTE IMMEDIATE $$\nCREATE TASK "), 7)
        for body in harness.task_bodies(original).values():
            self.assertIn("EXECUTE IMMEDIATE $$\n%s\n$$;" % body, derived)

    def test_plan_uses_cli_safe_tasks_and_one_session_test_pair(self):
        quietly(harness.action_render, args_for("render", self.out))
        plan = (self.out / "PLAN.txt").read_text(encoding="utf-8")
        self.assertIn("-f local/render/%s" % harness.CLI_TASKS, plan)
        self.assertIn("-f local/render/%s" % harness.CLI_TEST_PAIR, plan)
        self.assertNotIn("-f local/render/sql/06_tasks.sql", plan)
        self.assertNotIn("-f local/render/tests/fixtures.sql", plan)
        self.assertNotIn("-f local/render/tests/assertions.sql", plan)

    def test_plan_lists_install_files_in_order(self):
        quietly(harness.action_render, args_for("render", self.out))
        plan = (self.out / "PLAN.txt").read_text(encoding="utf-8")
        positions = [plan.index(name) for name in harness.INSTALL_FILES]
        self.assertEqual(positions, sorted(positions))

    def test_email_is_not_rendered(self):
        quietly(harness.action_render, args_for("render", self.out))
        self.assertFalse((self.out / "optional" / "email.sql").exists())
        self.assertNotIn("optional/email.sql", harness.INSTALL_FILES + harness.TEST_FILES)

    def test_rerender_refuses_without_force(self):
        quietly(harness.action_render, args_for("render", self.out))
        with self.assertRaises(harness.HarnessError):
            quietly(harness.action_render, args_for("render", self.out))
        self.assertEqual(
            quietly(harness.action_render, args_for("render", self.out, ["--force"])), 0
        )

    def test_bad_input_writes_nothing(self):
        bad = harness.build_parser().parse_args(
            ["render"] + GOOD[:1] + ["OUT__DB"] + GOOD[2:] + ["--out", str(self.out)]
        )
        with self.assertRaises(harness.HarnessError):
            quietly(harness.action_render, bad)
        self.assertFalse(self.out.exists())

    def test_create_schema_needs_the_confirmation_flag(self):
        with self.assertRaises(harness.HarnessError):
            quietly(harness.action_create_schema, args_for("create-schema", self.out))
        self.assertFalse(self.out.exists())

    def test_create_schema_writes_reviewable_ddl_only(self):
        args = args_for("create-schema", self.out, ["--approve-ddl"])
        self.assertEqual(quietly(harness.action_create_schema, args), 0)
        text = (self.out / "sql" / "00_create_schema.sql").read_text(encoding="utf-8")
        self.assertIn("CREATE SCHEMA OUTDB.OUTSCHEMA", text)
        self.assertIn("did not run it", text)


class PrivateOutputIsolationTests(unittest.TestCase):
    """Rendered copies must not disturb the source contract suite.

    The contract tests read the repository's own SQL. If they swept every
    directory, a rendered copy under local/ would double every object and fail
    the duplicate-definition check, so a render would break an unrelated suite.
    """

    def test_contract_suite_ignores_private_directories(self):
        source = (ROOT / "tests" / "test_contracts.py").read_text(encoding="utf-8")
        self.assertNotIn('rglob("*.sql")', source)
        for directory in harness.PRIVATE_ROOTS:
            self.assertNotIn('"%s"' % directory, source, directory)

    def test_render_targets_a_directory_git_excludes(self):
        ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").split()
        default = harness.build_parser().parse_args(
            ["render"] + GOOD
        ).out
        self.assertEqual(default.split("/")[0], "local")
        for directory in harness.PRIVATE_ROOTS:
            self.assertIn("%s/" % directory, ignored, directory)


class SafetyTests(unittest.TestCase):
    """The harness must be unable to reach Snowflake, the network, or a shell.

    These read the parsed module, not its prose, so a docstring that merely
    mentions a forbidden name cannot pass or fail a check by accident.
    """

    def setUp(self):
        self.tree = ast.parse(HARNESS_PATH.read_text(encoding="utf-8"))

    def imported_names(self):
        names = set()
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Import):
                names.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.module:
                    names.add(node.module.split(".")[0])
        return names

    def called_names(self):
        names = set()
        for node in ast.walk(self.tree):
            if not isinstance(node, ast.Call):
                continue
            target = node.func
            if isinstance(target, ast.Name):
                names.add(target.id)
            elif isinstance(target, ast.Attribute):
                names.add(target.attr)
        return names

    def test_harness_imports_only_the_standard_library(self):
        self.assertLessEqual(
            self.imported_names(), {"argparse", "re", "sys", "pathlib", "sql_lexer"}
        )

    def test_harness_imports_no_execution_or_network_module(self):
        forbidden = {"subprocess", "socket", "urllib", "http", "requests", "snowflake", "os"}
        self.assertEqual(self.imported_names() & forbidden, set())

    def test_harness_calls_nothing_that_could_execute(self):
        forbidden = {"system", "popen", "run", "call", "check_output", "eval", "exec",
                     "connect", "spawn", "execute", "fork"}
        self.assertEqual(self.called_names() & forbidden, set())


if __name__ == "__main__":
    unittest.main()
