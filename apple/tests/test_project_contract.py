import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("project_contract", Path(__file__).parents[1] / "check-project.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)

class ProjectContractTests(unittest.TestCase):
    def setUp(self):
        self.schemes, self.targets = contract.validate_project()

    def test_launching_helper_from_workbench_is_rejected(self):
        schemes = copy.deepcopy(self.schemes)
        ref = schemes["WorkBenchIOS"].find("LaunchAction/BuildableProductRunnable/BuildableReference")
        ref.set("BlueprintName", "PhotoAssistant")
        ref.set("BlueprintIdentifier", self.targets["PhotoAssistant"][0])
        ref.set("BuildableName", "PhotoAssistant.app")
        with self.assertRaisesRegex(contract.ConfigurationError, "LaunchAction"):
            contract.validate_schemes(schemes, self.targets)

    def test_archiving_both_apps_from_workbench_is_rejected(self):
        schemes = copy.deepcopy(self.schemes)
        for entry in schemes["WorkBenchIOS"].findall("BuildAction/BuildActionEntries/BuildActionEntry"):
            if entry.find("BuildableReference").get("BlueprintName") == "PhotoAssistant":
                entry.set("buildForArchiving", "YES")
        with self.assertRaisesRegex(contract.ConfigurationError, "Archiving"):
            contract.validate_schemes(schemes, self.targets)

    def test_wrong_profile_destination_is_rejected(self):
        schemes = copy.deepcopy(self.schemes)
        ref = schemes["PhotoAssistant"].find("ProfileAction/BuildableProductRunnable/BuildableReference")
        ref.set("BlueprintName", "WorkBenchIOS")
        with self.assertRaisesRegex(contract.ConfigurationError, "ProfileAction"):
            contract.validate_schemes(schemes, self.targets)

if __name__ == "__main__":
    unittest.main()
