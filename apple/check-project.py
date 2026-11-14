#!/usr/bin/env python3
"""Check generated Xcode run destinations and product isolation; no data/signing access."""
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
APPS = {
    "WorkBenchMac": ("随口记.app", "io.github.coderzhh.workbenchpreview", "随口记"),
    "WorkBenchIOS": ("WorkBench.app", "io.github.coderzhh.workbenchpreview.ios", "WorkBench"),
    "PhotoAssistant": ("PhotoAssistant.app", "io.github.coderzhh.workbenchpreview.photo", "拍照助手"),
}

class ConfigurationError(ValueError):
    pass

def require(condition, message):
    if not condition:
        raise ConfigurationError(message)

def project_objects():
    raw = subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-",
        str(ROOT / "Suikouji.xcodeproj/project.pbxproj"),
    ])
    return json.loads(raw)["objects"]

def validate_schemes(schemes, targets):
    require(set(schemes) == set(APPS), "共享运行方案应恰好对应三个 App")
    for name, (product, _, _) in APPS.items():
        scheme = schemes[name]
        for path in ["LaunchAction/BuildableProductRunnable/BuildableReference",
                     "ProfileAction/BuildableProductRunnable/BuildableReference",
                     "TestAction/MacroExpansion/BuildableReference"]:
            ref = scheme.find(path)
            require(ref is not None, f"{name} 缺少 {path}")
            require(ref.get("BlueprintName") == name and
                    ref.get("BlueprintIdentifier") == targets[name][0] and
                    ref.get("BuildableName") == product,
                    f"{name} 的 {path.split('/')[0]} 指向了其他产品")
        entries = scheme.findall("BuildAction/BuildActionEntries/BuildActionEntry")
        for action in ["Running", "Profiling", "Archiving", "Analyzing"]:
            active = [entry.find("BuildableReference").get("BlueprintName") for entry in entries
                      if entry.get("buildFor" + action) == "YES"]
            require(active == [name], f"{name} 的 {action} 包含其他产品：{active}")
        tested = {entry.find("BuildableReference").get("BlueprintName") for entry in entries
                  if entry.get("buildForTesting") == "YES"}
        expected = {name, "PhotoAssistant", "WorkBenchUITests"} if name == "WorkBenchIOS" else {name}
        require(tested == expected, f"{name} 的测试依赖不完整或混入其他产品")

def validate_project():
    objects = project_objects()
    targets = {value["name"]: (key, value) for key, value in objects.items()
               if value.get("isa") == "PBXNativeTarget"}
    actual_apps = {name for name, (_, value) in targets.items()
                   if value.get("productType") == "com.apple.product-type.application"}
    require(actual_apps == set(APPS), "工程主程序目标应只有三个")
    project = next(value for value in objects.values() if value.get("isa") == "PBXProject")
    project_configs = {
        objects[key]["name"]: objects[key]["buildSettings"]
        for key in objects[project["buildConfigurationList"]]["buildConfigurations"]
    }
    schemes = {path.stem: ET.parse(path).getroot() for path in
               (ROOT / "Suikouji.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme")}
    validate_schemes(schemes, targets)
    for name, (product, bundle, display) in APPS.items():
        target = targets[name][1]
        require(objects[target["productReference"]]["path"] == product, f"{name} 产品名称错误")
        dependencies = {objects[objects[key]["target"]]["name"]
                        for key in target.get("dependencies", []) if "target" in objects[key]}
        require(dependencies == ({"WorkBenchFocusActivity"} if name == "WorkBenchIOS" else set()),
                f"{name} 的应用/扩展依赖发生串线")
        for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            config = objects[key]
            settings = dict(project_configs[config["name"]], **config["buildSettings"])
            require(settings.get("PRODUCT_NAME") == product.removesuffix(".app"),
                    f"{name}/{config['name']} 的实际产物名与工程引用不一致")
            require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == bundle,
                    f"{name}/{config['name']} 的 Bundle ID 错误")
            global_flags = str(project_configs[config["name"]].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""))
            flags = str(settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")) + " " + global_flags
            require(("PHOTO_ASSISTANT" in flags) == (name == "PhotoAssistant"),
                    f"{name}/{config['name']} 的产品角色开关错误")
            with (ROOT / settings["INFOPLIST_FILE"]).open("rb") as handle:
                info = plistlib.load(handle)
            require(info.get("CFBundleDisplayName") == display, f"{name} 桌面显示名称错误")
    return schemes, targets

if __name__ == "__main__":
    try:
        validate_project()
    except (ConfigurationError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"工程检查失败：{error}")
    for name, (product, bundle, _) in APPS.items():
        print(f"{name} → {product} · {bundle}")
    print("三个产品的运行、测试、分析、归档和角色隔离检查通过。")
