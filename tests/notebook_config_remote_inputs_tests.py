"""Exercise the worker validation path used by remote cell-input transactions."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    worker = str(Path(sys.argv[1]).resolve())
    original = json.loads(Path("tools/notebook-macos/Samples/Config Editor.sputnikbook/project.json").read_text())
    local = original["sheets"][0]["cells"][2]["cell_ui"]
    sources = {"yaml": "# YAML\nepochs: 7\n", "toml": "# TOML\nepochs = 8\n"}
    local["inputs"] += [dict(id=fmt, title=fmt, type="string", default_json=json.dumps(text)) for fmt, text in sources.items()]
    local["pre"].append(dict(id="formats", title="Configs", kind="parameter_form", fields=[
        dict(input=fmt, control=dict(style="json", config_format=fmt)) for fmt in sources
    ]))
    with tempfile.TemporaryDirectory(prefix="sputnik-config-remote-") as directory:
        root = Path(directory)
        manifest, state, edits = [root / name for name in ("project.json", "state.json", "edits.json")]
        manifest.write_text(json.dumps(original))
        state.write_text("{}")

        def run(values):
            edits.write_text(json.dumps({key: json.dumps(value) for key, value in values.items()}))
            return subprocess.run([worker, "--cell-inputs", str(manifest), str(state), "3", str(edits)], capture_output=True, text=True, timeout=15)

        result = run(sources)
        assert result.returncode == 0, result.stderr
        accepted = json.loads(result.stdout)
        for fmt, text in sources.items():
            assert json.loads(accepted["values"]["3:" + fmt]) == text
        state.write_text(json.dumps(accepted["values"]))
        before = state.read_bytes()
        for values in [dict(yaml="x: [1, 2", toml="epochs = 99"), dict(yaml="epochs: 99", toml="x = ["),
                       dict(yaml="x: 1\nx: 2"), dict(toml="x = 1\nx = 2"), dict(yaml="x: &x [*x]")]:
            rejected = run(values)
            assert rejected.returncode != 0 and rejected.stderr.strip(), (values, rejected.stdout)
            assert state.read_bytes() == before
        sources = {"yaml": "# Accepted YAML\nepochs: 22\n", "toml": "# Accepted TOML\nepochs = 24\n"}
        result = run(sources)
        assert result.returncode == 0, result.stderr
        accepted = json.loads(result.stdout)
        for fmt, text in sources.items():
            assert json.loads(accepted["values"]["3:" + fmt]) == text
        # A host must reject an unknown parser rather than validating as JSON.
        local["pre"][-1]["fields"][0]["control"]["config_format"] = "unsupported"
        manifest.write_text(json.dumps(original))
        assert run({}).returncode != 0
    print("Remote config input validation passed: YAML/TOML, exact source, rejected batches and format settings")


if __name__ == "__main__":
    main()
