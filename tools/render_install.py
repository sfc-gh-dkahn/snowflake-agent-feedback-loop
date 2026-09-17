#!/usr/bin/env python3
"""Render private install SQL with your identifiers.

Run: python3 -B tools/render_install.py render --help

This tool reads repository files and writes configured copies under an ignored
directory. It runs no SQL and needs only the Python standard library.

Two actions:

  render         Substitute placeholders and write the ordered install files.
  create-schema  Write the one CREATE SCHEMA statement. Needs --approve-ddl.

Rendered output defaults to `local/render`, which Git ignores.
"""

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# The renderer and contract tests share one statement splitter.
sys.path.insert(0, str(ROOT / "tools"))

from sql_lexer import definition, statement_source, statements  # noqa: E402

# Install files, in the order they must run. Order is part of the contract:
# several objects use plain CREATE and depend on earlier files.
INSTALL_FILES = (
    "sql/00_setup.sql",
    "sql/01_preflight.sql",
    "sql/02_capture_context.sql",
    "sql/03_prepare_feedback.sql",
    "sql/04_diagnose.sql",
    "sql/05_recommend.sql",
    "sql/06_tasks.sql",
)

# Deterministic test pair, run later in a disposable schema, after install.
TEST_FILES = (
    "tests/fixtures.sql",
    "tests/assertions.sql",
)

# `optional/email.sql` is deliberately absent. Email is a separate approval and
# a separate manual install; this harness does not render it.

# Generated files for commands that must stay in one `snow sql` statement/session.
CLI_TASKS = "sql/06_tasks.cli.sql"
CLI_TEST_PAIR = "tests/fixture_pair.cli.sql"

# Directory names `.gitignore` already excludes. Rendered output must stay in one.
PRIVATE_ROOTS = ("local", "results", "logs")

# Mirrors sql/01_preflight.sql. An unquoted uppercase object identifier, which
# must not contain a double underscore so it cannot look like a placeholder.
IDENTIFIER = re.compile(r"[A-Z_][A-Z0-9_$]{0,254}")

# Mirrors sql/01_preflight.sql. Model names use model-name syntax, not object naming.
MODEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")

# A leftover placeholder. Requires an uppercase letter after the opening pair so
# the legitimate '__' string literals in sql/01_preflight.sql do not match.
PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]*__")

PLACEHOLDER_NAMES = (
    "__OUTPUT_DATABASE__",
    "__OUTPUT_SCHEMA__",
    "__AGENT_DATABASE__",
    "__AGENT_SCHEMA__",
    "__AGENT_NAME__",
    "__JUDGE_MODEL__",
    "__WAREHOUSE__",
)


class HarnessError(Exception):
    """A refusal the operator must fix. Never a partial write."""


def check_identifier(value, label):
    """Return an approved uppercase object identifier, or refuse."""
    if not IDENTIFIER.fullmatch(value or ""):
        raise HarnessError(
            "%s must be a simple uppercase unquoted identifier matching "
            "[A-Z_][A-Z0-9_$]{0,254}; got %r" % (label, value)
        )
    if "__" in value:
        raise HarnessError(
            "%s must not contain a double underscore, which would read as an "
            "unresolved placeholder; got %r" % (label, value)
        )
    return value


def check_model(value):
    """Return a syntactically valid model name, or refuse.

    Syntax only. This does not prove the account, region, or role permits the
    model, and it does not prove the model returns the required structured
    response. The first real AI call settles that, under its own approval.
    """
    if not MODEL.fullmatch(value or ""):
        raise HarnessError(
            "--judge-model must match model-name syntax "
            "[A-Za-z0-9][A-Za-z0-9_.-]{0,127}; got %r" % (value,)
        )
    return value


def check_agent(value):
    """Split DATABASE.SCHEMA.NAME into approved parts, or refuse."""
    parts = (value or "").split(".")
    if len(parts) != 3:
        raise HarnessError(
            "--agent must be a three-part DATABASE.SCHEMA.NAME; got %r" % (value,)
        )
    labels = ("--agent database", "--agent schema", "--agent name")
    return [check_identifier(part, label) for part, label in zip(parts, labels)]


def check_docs_service(value):
    """Split the documentation service into approved parts, or refuse."""
    parts = (value or "").split(".")
    if len(parts) != 3:
        raise HarnessError(
            "--docs-service must be a three-part DATABASE.SCHEMA.SERVICE; got %r"
            % (value,)
        )
    labels = (
        "--docs-service database",
        "--docs-service schema",
        "--docs-service name",
    )
    for part, label in zip(parts, labels):
        check_identifier(part, label)
    return value


def substitutions(settings):
    """Map every placeholder to an approved value."""
    return {
        "__OUTPUT_DATABASE__": settings["output_database"],
        "__OUTPUT_SCHEMA__": settings["output_schema"],
        "__AGENT_DATABASE__": settings["agent_database"],
        "__AGENT_SCHEMA__": settings["agent_schema"],
        "__AGENT_NAME__": settings["agent_name"],
        "__JUDGE_MODEL__": settings["judge_model"],
        "__WAREHOUSE__": settings["warehouse"],
    }


def render_text(source, values):
    """Substitute placeholders, then refuse if any placeholder survives."""
    rendered = source
    for name, value in values.items():
        rendered = rendered.replace(name, value)
    leftover = sorted(set(PLACEHOLDER.findall(rendered)))
    if leftover:
        raise HarnessError(
            "unresolved placeholder(s) after rendering: %s" % ", ".join(leftover)
        )
    return rendered


def task_bodies(source):
    """Return {task name: exact source text} for every CREATE TASK in source."""
    found = {}
    for chunk in statements(source):
        info = definition(chunk)
        if info and info[0] == "TASK":
            found[info[1]] = statement_source(source, chunk).strip()
    return found


def cli_safe_tasks(source):
    """Wrap task DDL so `snow sql` keeps each scripting body whole."""
    pieces = []
    wrapped = 0
    for chunk in statements(source):
        raw = statement_source(source, chunk).rstrip()
        info = definition(chunk)
        if info and info[0] == "TASK":
            if "$$" in raw:
                raise HarnessError(
                    "cannot derive a CLI-safe copy: task %s already contains $$, "
                    "which would terminate the EXECUTE IMMEDIATE wrapper" % info[1]
                )
            pieces.append("EXECUTE IMMEDIATE $$\n%s\n$$;" % raw)
            wrapped += 1
        else:
            pieces.append(raw)
    if not wrapped:
        raise HarnessError(
            "expected at least one CREATE TASK in %s; found none, so the CLI-safe "
            "copy would be pointless" % CLI_TASKS
        )

    header = (
        "-- Derived by tools/render_install.py. Do not edit; re-render instead.\n"
        "-- Use this file with `snow sql`. Each task uses EXECUTE IMMEDIATE so\n"
        "-- the CLI keeps its Snowflake Scripting body in one statement.\n\n"
    )
    text = header + "\n\n".join(pieces) + "\n"

    # Refuse the output if any task changed.
    before = task_bodies(source)
    after = {}
    for piece in text.split("EXECUTE IMMEDIATE $$\n")[1:]:
        after.update(task_bodies(piece.split("\n$$;")[0].strip()))
    if before != after:
        missing = sorted(set(before) ^ set(after))
        changed = sorted(name for name in set(before) & set(after) if before[name] != after[name])
        raise HarnessError(
            "CLI-safe derivation altered task text; refusing to write it. "
            "missing/extra=%s changed=%s" % (missing, changed)
        )
    return text, wrapped


def test_pair(fixtures, assertions):
    """Keep fixtures and assertions in one `snow sql` session."""
    return (
        "-- Derived by tools/render_install.py. Do not edit; re-render instead.\n"
        "-- Run this file once. It keeps the test transaction and temporary table\n"
        "-- in one session, then rolls back the fixture rows.\n\n"
        + fixtures.rstrip()
        + "\n\n"
        + assertions.rstrip()
        + "\n"
    )


def private_directory(raw, root=None):
    """Resolve the output directory and refuse anything git would track."""
    root = Path(root or ROOT)
    candidate = Path(raw)
    if not candidate.is_absolute():
        candidate = root / candidate
    candidate = candidate.resolve()
    root = root.resolve()
    try:
        relative = candidate.relative_to(root)
    except ValueError:
        raise HarnessError(
            "--out must stay inside the repository so the ignore rules apply; "
            "got %s" % (candidate,)
        )
    if not relative.parts or relative.parts[0] not in PRIVATE_ROOTS:
        raise HarnessError(
            "--out must start with one of the gitignored directories (%s) so a "
            "configured copy cannot be committed; got %s"
            % (", ".join(PRIVATE_ROOTS), relative or ".")
        )
    return candidate


def read_source(name, root=None):
    path = Path(root or ROOT) / name
    if not path.is_file():
        raise HarnessError("missing repository file: %s" % name)
    return path.read_text(encoding="utf-8")


def write_file(path, text, force):
    if path.exists() and not force:
        raise HarnessError(
            "refusing to overwrite %s; pass --force once you have checked it" % path
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def display_path(path):
    """Path relative to the repository root, or absolute if it sits outside.

    Both sides are resolved first, because a repository reached through a
    symlink would otherwise fail the comparison.
    """
    resolved = Path(path).resolve()
    try:
        return str(resolved.relative_to(Path(ROOT).resolve()))
    except ValueError:
        return str(resolved)


def settings_from(args):
    """Validate every input before anything is written."""
    agent_database, agent_schema, agent_name = check_agent(args.agent)
    return {
        "output_database": check_identifier(args.output_database, "--output-database"),
        "output_schema": check_identifier(args.output_schema, "--output-schema"),
        "agent_database": agent_database,
        "agent_schema": agent_schema,
        "agent_name": agent_name,
        "warehouse": check_identifier(args.warehouse, "--warehouse"),
        "role": check_identifier(args.role, "--role"),
        "judge_model": check_model(args.judge_model),
        "docs_service": check_docs_service(args.docs_service),
    }


def connection_flag(connection):
    """Return the `snow sql` connection flag, or nothing for the default."""
    return " -c %s" % connection if connection else ""


def plan_lines(settings, out, rendered, task_count, connection):
    """The exact paths and the exact next commands, in order."""
    flag = connection_flag(connection)
    qualified = "%s.%s" % (settings["output_database"], settings["output_schema"])
    lines = [
        "Rendered install plan",
        "=====================",
        "",
        "Target output schema : %s" % qualified,
        "Reviewed agent       : %s.%s.%s (read-only; never altered)"
        % (settings["agent_database"], settings["agent_schema"], settings["agent_name"]),
        "Warehouse            : %s" % settings["warehouse"],
        "Role                 : %s" % settings["role"],
        "Judge model          : %s (syntax checked only)" % settings["judge_model"],
        "Docs search service  : %s" % settings["docs_service"],
        "Output directory     : %s" % out,
        "",
        "Rendered files:",
    ]
    for index, path in enumerate(rendered, 1):
        lines.append("  %2d. %s" % (index, path))
    lines += [
        "",
        "Next commands",
        "",
        "1. If needed, write the empty-schema DDL for review:",
        "     python3 -B tools/render_install.py create-schema --approve-ddl \\",
        "       --output-database %s --output-schema %s \\"
        % (settings["output_database"], settings["output_schema"]),
        "       --agent %s.%s.%s --warehouse %s --role %s \\"
        % (
            settings["agent_database"],
            settings["agent_schema"],
            settings["agent_name"],
            settings["warehouse"],
            settings["role"],
        ),
        "       --judge-model %s --docs-service %s"
        % (settings["judge_model"], settings["docs_service"]),
        "   Then review and run the printed file with snow sql.",
        "",
        "2. Install the first six files in order:",
    ]
    for name in INSTALL_FILES[:-1]:
        lines.append("     snow sql%s --role %s -f %s" % (
            flag, settings["role"], rendered[name]
        ))
    lines += [
        "",
        "3. Install the %d suspended tasks with the CLI-safe file:" % task_count,
        "     snow sql%s --role %s -f %s" % (
            flag, settings["role"], rendered[CLI_TASKS]
        ),
        "",
        "4. Run the tests in one CLI session:",
        "     snow sql%s --role %s -f %s" % (
            flag, settings["role"], rendered[CLI_TEST_PAIR]
        ),
    ]
    lines += [
        "",
        "5. Run the no-AI preflight:",
        "     snow sql%s --role %s -q \"CALL %s.AF_PREFLIGHT();\""
        % (flag, settings["role"], qualified),
        "   Require ok = true and inference_performed = false.",
        "",
        "6. Set the documentation service:",
        "     snow sql%s --role %s -q \"UPDATE %s.AF_CONFIG SET docs_service = "
        "'%s' WHERE config_id = 1;\""
        % (flag, settings["role"], qualified, settings["docs_service"]),
        "",
        "Not run by this tool: AI inference, email, or scheduling.",
        "",
        "This harness ran no SQL. Nothing above has been executed.",
    ]
    return lines


def action_render(args):
    settings = settings_from(args)
    out = private_directory(args.out)
    values = substitutions(settings)

    # Render everything in memory first, so a late refusal writes nothing.
    documents = []
    for name in INSTALL_FILES + TEST_FILES:
        documents.append((name, render_text(read_source(name), values)))
    rendered = dict(documents)

    # Derive CLI files after substitution.
    cli_tasks, task_count = cli_safe_tasks(rendered["sql/06_tasks.sql"])
    documents.append((CLI_TASKS, cli_tasks))
    documents.append(
        (CLI_TEST_PAIR, test_pair(rendered["tests/fixtures.sql"], rendered["tests/assertions.sql"]))
    )

    written = {}
    for name, text in documents:
        target = out / name
        write_file(target, text, args.force)
        written[name] = display_path(target)

    lines = plan_lines(settings, display_path(out), written, task_count, args.connection)
    plan_path = out / "PLAN.txt"
    write_file(plan_path, "\n".join(lines) + "\n", True)
    print("\n".join(lines))
    print("\nPlan saved to %s" % display_path(plan_path))
    return 0


def action_create_schema(args):
    """Write the one CREATE SCHEMA statement. Executes nothing."""
    if not args.approve_ddl:
        raise HarnessError(
            "create-schema needs --approve-ddl. It writes a CREATE SCHEMA "
            "statement for you to review and run; nothing runs here."
        )
    settings = settings_from(args)
    out = private_directory(args.out)
    qualified = "%s.%s" % (settings["output_database"], settings["output_schema"])
    statement = (
        "-- Review before running. This harness did not run it.\n"
        "-- Plain CREATE, deliberately: it fails if the schema already exists,\n"
        "-- rather than reusing a schema that may not be empty. Check first, and\n"
        "-- do not point a populated installation at a different agent.\n"
        "USE ROLE %s;\n"
        "USE WAREHOUSE %s;\n"
        "CREATE SCHEMA %s;\n"
        % (settings["role"], settings["warehouse"], qualified)
    )
    target = out / "sql" / "00_create_schema.sql"
    write_file(target, statement, args.force)
    relative = display_path(target)
    print("Wrote %s\n" % relative)
    print(statement)
    print(
        "Nothing executed. Run it yourself once you approve the DDL:\n"
        "  snow sql%s --role %s -f %s"
        % (connection_flag(args.connection), settings["role"], relative)
    )
    print(
        "\nCheck the schema does not already exist first:\n"
        "  snow sql%s --role %s -q \"SHOW SCHEMAS LIKE '%s' IN DATABASE %s;\""
        % (
            connection_flag(args.connection),
            settings["role"],
            settings["output_schema"],
            settings["output_database"],
        )
    )
    return 0


def add_common(parser):
    parser.add_argument("--output-database", required=True, help="approved output database")
    parser.add_argument("--output-schema", required=True, help="empty output schema")
    parser.add_argument("--agent", required=True, help="existing agent DATABASE.SCHEMA.NAME")
    parser.add_argument("--warehouse", required=True, help="warehouse for the tasks")
    parser.add_argument("--role", required=True, help="role you will use explicitly")
    parser.add_argument("--judge-model", required=True, help="permitted judge model")
    parser.add_argument(
        "--docs-service",
        required=True,
        help="discovered Cortex Search service DATABASE.SCHEMA.SERVICE",
    )
    parser.add_argument(
        "--out",
        default="local/render",
        help="private output directory; must sit under %s (default: local/render)"
        % "/, ".join(PRIVATE_ROOTS),
    )
    parser.add_argument("--connection", default=None, help="snow sql connection name")
    parser.add_argument("--force", action="store_true", help="overwrite existing files")


def build_parser():
    parser = argparse.ArgumentParser(
        prog="render_install.py",
        description="Render the install SQL privately. Runs no SQL.",
    )
    actions = parser.add_subparsers(dest="action", required=True)

    render = actions.add_parser("render", help="write the ordered install files")
    add_common(render)
    render.set_defaults(handler=action_render)

    schema = actions.add_parser("create-schema", help="write the CREATE SCHEMA statement")
    add_common(schema)
    schema.add_argument(
        "--approve-ddl",
        action="store_true",
        help="required; confirms you approve writing schema DDL",
    )
    schema.set_defaults(handler=action_create_schema)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except HarnessError as error:
        print("refused: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
