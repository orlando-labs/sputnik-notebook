# Tooling dependencies

Do not introduce Python dependencies into builds, tests, package generation,
container preparation, launchers or deployment tools. Write behavior and test
fixtures in Sputnik; use shell for small orchestration scripts.

Python execution for explicitly requested notebook content is an optional
foreign-language capability. It must not be required to build, test, start or
operate the Sputnik core or its base Docker image.

Preserve existing regression coverage when replacing tooling. Unrelated legacy
scripts are not a reason to add Python to a new dependency chain.
