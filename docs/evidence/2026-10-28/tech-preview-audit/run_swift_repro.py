"""Build the audit main against the repository's actual Swift model sources."""
from pathlib import Path
import shlex
import subprocess
import tempfile

evidence = Path(__file__).resolve().parent
repo = evidence.parents[3]
temporary = Path(tempfile.mkdtemp(prefix="notebook-swift-audit-"))
dry_run = subprocess.check_output(
    ["make", "-n", "-W", "tests/notebook_macos_model_tests.swift", "build/notebook_macos_model_tests"],
    cwd=repo, text=True,
)
line = next(line for line in dry_run.splitlines()
            if line.startswith("xcrun swiftc ") and "tests/notebook_macos_model_tests.swift" in line)
arguments = shlex.split(line)
arguments[arguments.index("tests/notebook_macos_model_tests.swift")] = str(evidence / "swift_repro.swift")
arguments[arguments.index("-o") + 1] = str(temporary / "audit")
with (temporary / "build.log").open("w") as log:
    subprocess.run(arguments, cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True)
subprocess.run([str(temporary / "audit"), str(temporary / "fixtures"), str(repo)], cwd=repo, check=True)
print("Evidence directory:", temporary)
