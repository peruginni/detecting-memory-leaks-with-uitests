import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "helpers"))
from check_xctrace_leaks import analyze
from leak_report import parse_leaks_report, print_summary


class LeakReportTests(unittest.TestCase):
    def test_groups_types_and_preserves_non_app_allocations(self):
        text = """Process 123: 3 leaks for 208 total leaked bytes.
Leak: 0x1  size=96  zone: TestZone   DetailScreenModel  Swift  MyApp
Leak: 0x2  size=96  zone: TestZone   DetailScreenModel  Swift  MyApp
Leak: 0x3  size=16  zone: TestZone   Publisher.lock (malloc)    Combine
"""
        counts, app = parse_leaks_report(text)
        self.assertEqual(dict(counts), {"MyApp.DetailScreenModel": 2, "Publisher.lock (malloc)": 1})
        self.assertEqual(dict(app), {"MyApp.DetailScreenModel": 2})
        with contextlib.redirect_stdout(io.StringIO()) as output:
            print_summary(counts, app)
        self.assertIn("DetailScreenModel × 2", output.getvalue())
        self.assertIn("Publisher.lock (malloc) × 1", output.getvalue())

    def test_clean_report(self):
        self.assertEqual(parse_leaks_report("Process 123: 0 leaks for 0 total leaked bytes."), ({}, {}))

    def test_missing_truncated_or_malformed_report_fails(self):
        for text in ["", "tool failed", "Process 123: 1 leaks for 96 total leaked bytes.",
                     "Process 123: 1 leaks for 96 total leaked bytes.\nLeak: invalid"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_leaks_report(text)


class AllocationRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def write_table(self, name, rows):
        root = ET.Element("trace-query-result")
        node = ET.SubElement(root, "node")
        for row in rows:
            ET.SubElement(node, "row", row)
        path = self.directory / name
        ET.ElementTree(root).write(path)
        return path

    def test_only_recovers_unambiguous_live_address_and_size_matches(self):
        leaks = self.write_table("leaks.xml", [
            {"address": hex(i), "size": "80", "leaked-object": name, "count": "1"}
            for i, name in [(1, "Malloc 80 Bytes"), (2, "Malloc 80 Bytes"),
                            (3, "Malloc 80 Bytes"), (4, "ExistingName"),
                            (5, "Malloc 80 Bytes"), (6, "Malloc 80 Bytes")]
        ])
        allocations = self.write_table("allocations.xml", [
            {"address": hex(i), "size": size, "live": live, "category": category}
            for i, size, live, category in [
                (1, "80", "true", "MyApp.DetailScreenModel"),
                (2, "80", "false", "FreedType"), (3, "96", "true", "WrongSize"),
                (4, "80", "true", "OtherName"), (5, "80", "true", "TypeA"),
                (5, "80", "true", "TypeB")]
        ])
        counts, recovered = analyze(leaks, allocations)
        self.assertEqual(dict(counts), {"MyApp.DetailScreenModel": 1, "Malloc 80 Bytes": 4, "ExistingName": 1})
        self.assertEqual(recovered, [("0x1", "Malloc 80 Bytes", "MyApp.DetailScreenModel")])

    def test_empty_tables_are_clean_but_missing_tables_are_not(self):
        empty = self.write_table("empty.xml", [])
        self.assertEqual(analyze(empty, empty), ({}, []))
        missing = self.directory / "missing.xml"
        missing.write_text("<trace-query-result/>")
        with self.assertRaises(ValueError):
            analyze(missing, empty)

    def test_invalid_count_fails(self):
        leaks = self.write_table("leaks.xml", [{"leaked-object": "SomeType", "count": "0"}])
        empty = self.write_table("empty.xml", [])
        with self.assertRaises(ValueError):
            analyze(leaks, empty)


if __name__ == "__main__":
    unittest.main()
