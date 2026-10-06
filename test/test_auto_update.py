import copy
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from ruamel.yaml import YAML

import auto_update


def grid_version(version):
    return {
        "DriverVersion": version,
        "Drivers": [{
            "DirLink": (
                "https://download.microsoft.com/download/test/"
                f"NVIDIA-Linux-x86_64-{version}-grid-azure.run"
            ),
        }],
    }


def driver_data():
    return {
        "Latest": [{
            "Category": [{
                "Name": "GRID",
                "Versions": [grid_version("595.91.07")],
            }],
        }],
        "Archive": [{
            "Category": [{
                "Name": "GRID",
                "Versions": [grid_version("580.178.04"), grid_version("570.237")],
            }],
        }],
    }


class GridDriverUpdateTests(unittest.TestCase):
    def test_selects_lts_from_archive_and_v20_from_latest(self):
        for branch, expected in (("580", "580.178.04"), ("595", "595.91.07")):
            with self.subTest(branch=branch):
                version, url = auto_update.get_latest_grid_driver(driver_data(), branch)
                self.assertEqual(version, expected)
                self.assertTrue(url.endswith(f"{expected}-grid-azure.run"))

    def test_selects_highest_numeric_version_within_branch(self):
        data = driver_data()
        data["Archive"][0]["Category"][0]["Versions"].extend([
            grid_version("580.99.01"),
            grid_version("580.180.01"),
        ])
        version, _ = auto_update.get_latest_grid_driver(data, "580")
        self.assertEqual(version, "580.180.01")

    def test_missing_branch_fails_instead_of_switching_to_latest(self):
        with self.assertRaisesRegex(ValueError, "Could not find GRID R580"):
            auto_update.get_latest_grid_driver(
                {"Latest": driver_data()["Latest"], "Archive": []}, "580"
            )

    def test_rejects_invalid_upstream_version(self):
        data = driver_data()
        data["Latest"][0]["Category"][0]["Versions"][0]["DriverVersion"] = "invalid"
        with self.assertRaisesRegex(ValueError, "Unexpected driver version"):
            auto_update.get_latest_grid_driver(data, "595")

    def test_rejects_untrusted_driver_url(self):
        data = driver_data()
        data["Archive"][0]["Category"][0]["Versions"][0]["Drivers"][0]["DirLink"] = (
            "https://example.com/driver.run"
        )
        with self.assertRaisesRegex(ValueError, "Driver URL host is not allowed"):
            auto_update.get_latest_grid_driver(data, "580")

    def test_rejects_installer_for_a_different_driver_version(self):
        data = driver_data()
        data["Archive"][0]["Category"][0]["Versions"][0]["Drivers"] = (
            grid_version("595.91.07")["Drivers"]
        )
        with self.assertRaisesRegex(ValueError, "Driver URL does not match GRID version"):
            auto_update.get_latest_grid_driver(data, "580")

    def test_fetch_uses_timeout_and_propagates_http_errors(self):
        response = Mock()
        response.raise_for_status.side_effect = auto_update.requests.HTTPError("failed")
        with patch.object(auto_update.requests, "get", return_value=response) as get:
            with self.assertRaises(auto_update.requests.HTTPError):
                auto_update.get_grid_driver_data()
            self.assertEqual(get.call_args.kwargs["timeout"], 30)
            response.json.assert_not_called()

    def test_update_preserves_lts_v20_and_cuda_separation(self):
        original = {
            "cuda": {"version": "595.71.05"},
            "cuda_lts": {"version": "580.159.04"},
            "grid": {"version": "580.100.01", "url": "old"},
            "grid_v20": {"version": "595.58.03", "url": "old"},
        }
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "driver_config.yml"
            yaml = YAML()
            with config_path.open("w") as config:
                yaml.dump(copy.deepcopy(original), config)
            previous_directory = os.getcwd()
            try:
                os.chdir(directory)
                with patch.object(auto_update, "get_grid_driver_data", return_value=driver_data()):
                    auto_update.update_driver_config()
            finally:
                os.chdir(previous_directory)
            with config_path.open() as config:
                updated = yaml.load(config)
        self.assertEqual(updated["grid"]["version"], "580.178.04")
        self.assertEqual(updated["grid_v20"]["version"], "595.91.07")
        self.assertEqual(updated["cuda"], original["cuda"])
        self.assertEqual(updated["cuda_lts"], original["cuda_lts"])

    def test_update_refuses_to_downgrade_and_leaves_config_unchanged(self):
        original = {
            "grid": {"version": "580.180.01", "url": "old"},
            "grid_v20": {"version": "595.91.07", "url": "old"},
        }
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "driver_config.yml"
            yaml = YAML()
            with config_path.open("w") as config:
                yaml.dump(original, config)
            before = config_path.read_text()
            previous_directory = os.getcwd()
            try:
                os.chdir(directory)
                with patch.object(auto_update, "get_grid_driver_data", return_value=driver_data()):
                    with self.assertRaisesRegex(ValueError, "Refusing to downgrade grid"):
                        auto_update.update_driver_config()
            finally:
                os.chdir(previous_directory)
            self.assertEqual(config_path.read_text(), before)

    def test_checked_in_config_keeps_grid_branch_and_installer_consistent(self):
        path = Path(__file__).resolve().parents[1] / "driver_config.yml"
        with path.open() as config:
            data = YAML().load(config)
        for key, branch in (("grid", "580"), ("grid_v20", "595")):
            with self.subTest(key=key):
                version = data[key]["version"]
                self.assertEqual(version.split(".")[0], branch)
                self.assertTrue(data[key]["url"].endswith(f"{version}-grid-azure.run"))


if __name__ == "__main__":
    unittest.main()
