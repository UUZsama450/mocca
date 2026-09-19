#!/usr/bin/env python3
"""Offline attribution/adjacency checks plus optional read-only 5032 regression."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import analyze_tools_presentation as analyzer

FIXTURE = None


def update(key, pid=7, display="Update Display"):
    return {"key": (key, 1), "pid": pid, "display": display, "start_s": 0., "end_s": 1.}


def swap(key, timestamp, display="Swap Display"):
    return {"key": (key, 1), "timestamp_s": timestamp, "desired_s": timestamp - .001,
            "generation_s": timestamp - .010, "hid_s": .001, "display": display, "min_quanta": 2}


class AttributionChecks(unittest.TestCase):
    def test_unmatched_row_is_an_adjacency_barrier(self):
        ss = [swap(1, 0), swap(2, .008), swap(3, .016), swap(4, .024)]
        quality = analyzer.attribute([update(1), update(3), update(4)], ss, 7)
        result = analyzer.window_metrics(ss, 0, 1)
        actual = result["strict_exact_target_adjacent_pairs"]["actual_swap_gap_ms"]
        self.assertEqual(actual["count"], 1)
        self.assertAlmostEqual(actual["median"], 8.)
        self.assertEqual(result["rejected_pair_count"], 2)
        self.assertEqual(quality["ambiguous_update_keys"], 0)

    def test_cross_pid_collision_cannot_become_target_match(self):
        ss = [swap(1, 0), swap(2, .008)]
        quality = analyzer.attribute([update(1), update(1, pid=8), update(2)], ss, 7)
        self.assertFalse(ss[0]["matched"])
        self.assertTrue(ss[1]["matched"])
        self.assertEqual(quality["ambiguous_update_keys"], 1)
        self.assertEqual(analyzer.window_metrics(ss, 0, 1)["strict_exact_target_adjacent_pairs"]["actual_swap_gap_ms"]["count"], 0)

    def test_duplicate_swap_records_remain_barriers(self):
        ss = [swap(1, 0), swap(1, .008), swap(2, .016), swap(3, .024)]
        quality = analyzer.attribute([update(1), update(2), update(3)], ss, 7)
        self.assertEqual(quality["duplicate_swap_keys"], 1)
        self.assertEqual([s["matched"] for s in ss], [False, False, True, True])
        self.assertEqual(analyzer.window_metrics(ss, 0, 1)["strict_exact_target_adjacent_pairs"]["actual_swap_gap_ms"]["count"], 1)

    def test_ambiguous_display_mapping_fails_closed(self):
        ss = [swap(1, 0, "Display A"), swap(2, .008, "Display B")]
        quality = analyzer.attribute([update(1), update(2)], ss, 7)
        self.assertTrue(quality["ambiguous_display_mapping"])
        self.assertFalse(any(s["matched"] for s in ss))

    def test_xml_refs_and_incomplete_xml(self):
        xml = '<table><schema name="hitches-updates"><col><mnemonic>start</mnemonic></col></schema><row><start-time id="1" fmt="00:00.001.000">1000000</start-time></row><row><start-time ref="1"/></row></table>'
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "test.xml"
            path.write_text(xml)
            rows, quality = analyzer.read_table(path, "hitches-updates")
            self.assertEqual(len(rows), 2)
            self.assertIs(rows[0]["start"], rows[1]["start"])
            self.assertEqual(quality["timestamp_calibration"]["raw"], 1000000)
            path.write_text(xml.removesuffix("</table>"))
            with self.assertRaises(ET.ParseError):
                analyzer.read_table(path, "hitches-updates")

    def test_failed_export_receipt_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            directory = Path(td)
            (directory / "export-receipts.json").write_text(json.dumps([{"schema": "hitches-updates", "exit_code": -11, "complete_xml_parse": False}]))
            with self.assertRaisesRegex(ValueError, "not successful"):
                analyzer.check_receipt(directory, "hitches-updates", directory / "hitches-updates.xml")


class RealFixtureChecks(unittest.TestCase):
    def setUp(self):
        if FIXTURE is None:
            self.skipTest("Pass --fixture-run for the physical 5032 regression")

    def test_reproduce_strict_windows_without_modifying_fixture(self):
        paths = [FIXTURE / "presentation" / (name + ".xml") for name in ("hitches-updates", "display-surface-swap")]
        before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
        actual = analyzer.analyze(FIXTURE, 15946, FIXTURE / "phase-envelopes.json", ["more-instruction:1"], "target-surface-pool")
        self.assertEqual(actual["quality"]["exact_target_matches"], 706)
        self.assertEqual(actual["quality"]["ambiguous_update_keys"], 0)
        self.assertEqual(actual["central_window_group_median_bands"], {"near_8_33_ms": 12, "near_16_67_ms": 12, "explicitly_excluded": 1})
        expected = json.loads((FIXTURE / "presentation/swap-cadence.json").read_text())
        self.assertEqual(len(actual["segments"]), len(expected["phases"]))
        for observed, old in zip(actual["segments"], expected["phases"]):
            self.assertEqual(len(observed["input_groups"]), len(old["input_groups"]))
            for new_group, old_group in zip(observed["input_groups"], old["input_groups"]):
                self.assertEqual(new_group["last_hid_s"], old_group["last_hid_s"])
                self.assertIsNone(new_group["user_label"])
                for name in analyzer.WINDOWS:
                    new = new_group["windows"][name]["strict_exact_target_adjacent_pairs"]
                    old_window = old_group["windows"][name]["strict_exact_mocca_adjacent_pairs"]
                    for metric in ("actual_swap_gap_ms", "desired_presentation_gap_ms", "generation_gap_ms"):
                        self.assertEqual(new[metric]["count"], old_window[metric]["count"])
                        self.assertAlmostEqual(new[metric]["median"], old_window[metric]["median"], places=9)
        self.assertEqual(before, [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths])

    def test_default_has_no_setup_or_route_assumption(self):
        result = analyzer.analyze(FIXTURE, 15946)
        self.assertEqual([s["segment"]["id"] for s in result["segments"]], ["all"])
        groups = result["segments"][0]["input_groups"]
        self.assertGreater(len(groups), 0)
        self.assertTrue(all(g["user_label"] is None and not g["excluded_by_user"] for g in groups))
        self.assertNotIn("direction", json.dumps(groups))
        with self.assertRaisesRegex(ValueError, "Unknown excluded"):
            analyzer.analyze(FIXTURE, 15946, exclusions=["all:9999"])

    def test_new_exports_directory_and_receipts(self):
        old = json.loads((FIXTURE / "presentation/export-receipts.json").read_text())
        with tempfile.TemporaryDirectory() as td:
            run = Path(td)
            exports = run / "exports"
            exports.mkdir()
            for name in ("hitches-updates", "display-surface-swap"):
                (exports / (name + ".xml")).symlink_to((FIXTURE / "presentation" / (name + ".xml")).resolve())
                receipt = next(r for r in old if r["schema"] == name)
                (exports / (name + "-receipt.json")).write_text(json.dumps({
                    "exit_code": 0, "complete_xml_parse": True, "rows": receipt["row_count"], "bytes": receipt["bytes"]}))
            (exports / "toc.xml").symlink_to((FIXTURE / "zombie-diagnostic/toc.xml").resolve())
            result = analyzer.analyze(run, 15946)
            self.assertEqual(result["quality"]["exact_target_matches"], 706)
            self.assertEqual(result["quality"]["toc_target_run"]["pid"], 15946)
            self.assertEqual(result["segments"][0]["segment"]["start_s"], 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-run", type=Path)
    args = parser.parse_args()
    FIXTURE = args.fixture_run
    unittest.main(argv=[__file__], verbosity=2)
