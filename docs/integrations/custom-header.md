# Recon-Ry custom header integration

- **Intent:** expose repeatable `--header 'Name: value'` for authentication and program-required HTTP headers while preserving `--auth-header` compatibility.
- **Branch / base / target:** `fix/custom-header` from `f202dfc68ff7ae0303f8366267912a9d18018d53`; target the repository's current `main` integration lane.
- **Worktree:** `/home/ryushe/worktrees/recon-ry-custom-header`.
- **Contract:** Katana, httpx, ffuf, and Nuclei receive native `-H` arguments; HTTP fingerprinting and param_recon receive their wrapper `--header` option; passive and network stages receive no headers; command logging redacts values.
- **Compatibility:** `--auth-header` remains an alias at public and internal wrapper boundaries.
- **Evidence:** implementation commit `86c2e9f`; `bash -n` passed; Python compilation passed; `./main.sh selftest` passed, including per-tool header forwarding and alias checks. Independent release review approved the commit and reran the self-test, exact argv/redaction checks, fingerprint execution, and param_recon forwarding.
- **Activation boundary:** Hoster deployment is separate and must preserve its dirty runtime checkout before applying the reviewed commit.
- **Next:** publish the feature ref, preserve Hoster runtime changes, apply the reviewed implementation commit, and run offline Hoster smoke checks.
