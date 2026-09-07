# LucasCad

A thoughtfully developed, local-first, browser-driven analog to popular sketch-based CAD software.

## License

Copyright (c) 2026 LucasCad contributors.

LucasCad's project-original source code is free software: you can redistribute
it and/or modify it under the terms of the GNU General Public License, version 3
only (`GPL-3.0-only`), as published by the Free Software Foundation.

It is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See [LICENSE](LICENSE) for the complete terms.

This grant covers LucasCad-original application, backend, test and tooling code.
Third-party code, dependencies and notices retain their
upstream terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No rights in
third-party material or unapproved example models/images are granted by this notice.
The [release audit](docs/release-audit.md) still contains unresolved distribution checks.

## Release status

Experimental local-only software, not a production-ready network service or a
certified engineering tool. The [release audit](docs/release-audit.md) records
open security, licensing and provenance findings. Read [third-party notices](THIRD_PARTY_NOTICES.md)
and [security guidance](SECURITY.md) before redistributing or deploying it.
Public source availability is not a blanket license for bundled dependencies.
Source-archive exclusions preserve owner models locally while omitting selected
unapproved artifacts from `git archive`. They do not sanitize Git history or make
an installer cleared for redistribution. See [provenance and release decisions](docs/release/provenance.md).

The current vertical slice uses Open CASCADE through CadQuery for exact B-Rep
geometry and STEP export. Three.js displays a tessellated copy of each exact
face for interactive orbiting and face selection.

## Run locally

LucasCad runs on macOS, Linux, and Windows. The launcher handles first-time
setup for you: it creates the Python virtualenv, installs the geometry kernel,
installs Node dependencies, starts both services, and opens the browser.

**macOS and Linux**

```bash
./start-cad.sh
```

Or, on macOS, double-click **Start LucasCad.command** in Finder.

**Windows**

Double-click **Start LucasCad.bat**, or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\start-cad.ps1
```

Windows blocks unsigned scripts by default, so a bare `.\start-cad.ps1` fails
with "running scripts is disabled on this system" until you either use the
`.bat` (which sets the policy for that one run) or allow local scripts once:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Dependencies are always installed on the target machine. Do not copy another
machine's `.venv` or `node_modules`; the launcher builds both locally and
installs Node packages from the frozen lockfile.

The first run downloads roughly 400 MB of Open CASCADE and takes a few minutes.
Later runs start in seconds. Press `Ctrl+C` to stop both services.

The script starts the geometry service on `127.0.0.1:4311` and the browser UI
at `http://lucascad.localhost:4310`. The dedicated ports keep LucasCad from
competing with other local development applications.

### Prerequisites

The launcher checks for these and prints install instructions if either is
missing or too old:

| Requirement | Version | Notes |
| --- | --- | --- |
| Python | 3.11 – 3.14 | CadQuery 2.8 requires >= 3.11. The macOS system Python (3.9) is too old; install `python@3.12`. |
| Node.js | >= 22.13 | Set by `engines` in `package.json`. Use a security-patched release. |

pnpm does not need to be installed. The version is pinned by `packageManager`
in `package.json`, which recent pnpm releases honour by switching to it
automatically; the launcher installs a private copy under `.tooling/` when the
system pnpm cannot.

The geometry kernel also needs one platform runtime library that LucasCad
itself does not. The launcher detects both cases and prints the exact fix:

| Platform | Needs | Install |
| --- | --- | --- |
| Windows | Visual C++ Redistributable | `winget install Microsoft.VCRedist.2015+.x64`. A clean Windows install ships no C++ runtime, so CadQuery's compiled extensions fail with "DLL load failed". |
| Linux | libGL and X11 client libraries | `sudo apt-get install -y libgl1 libglx-mesa0 libxrender1 libxext6 libsm6 libice6`. OCP links VTK against libGL even though all rendering happens in your browser. |

### Options

```bash
./start-cad.sh --setup-only   # install dependencies, then exit
./start-cad.sh --no-open      # do not open a browser
```

| Variable | Purpose |
| --- | --- |
| `LUCASCAD_PYTHON` | Use a specific Python interpreter |
| `LUCASCAD_WEB_PORT` | Web UI port (default 4310) |
| `LUCASCAD_API_PORT` | Geometry service port (default 4311) |

## Validate

**macOS and Linux**

```bash
./scripts/run-tests.sh            # backend and frontend
./scripts/run-tests.sh backend    # pytest only
./scripts/run-tests.sh frontend   # pnpm test only
```

**Windows**

```powershell
.\.venv\Scripts\python.exe -m pytest backend -q
pnpm test
pnpm run test:dependencies
pnpm run test:release
```

Run `.\start-cad.ps1 -SetupOnly` first if the environment does not exist yet.

The backend tests verify sketch diagnostics, document replay, Boolean cuts,
exact volume, solid validity, STEP generation, STEP re-import, and volume
preservation. The frontend contract tests run with `pnpm test`.

## Current feature slice

- Open CASCADE box feature generated from a rectangular sketch definition
- Feature tree and origin planes
- Freeform chained lines and construction centerlines
- Corner rectangles, circles, ellipses, exact three-point arcs, and connected splines
- Endpoint, midpoint, center, quadrant, grid, horizontal, and vertical snapping
- Automatic coincident, horizontal, vertical, and concentric relation markers
- Automatic entity dimensions with double-click numeric editing
- Connected-endpoint propagation when dimensions rebuild geometry
- Undo, redo, trim/remove, selection, and keyboard shortcuts
- Ribbon New Sketch always creates a new sketch after choosing XY, XZ, YZ, or a selected planar body face
- Finished sketches remain visible in amber in the 3D viewport and do not create a feature automatically
- Extrude and Revolve first prompt for a sketch and report empty, open, or degenerate geometry with endpoint diagnostics
- Closed sketch profiles drive exact Open CASCADE extrusions with new-body, union, and cut result modes
- Closed sketch profiles drive partial or full revolutions
- Revolve axes from a construction centerline, origin axis, or profile edge
- Constant-radius edge Fillet and symmetric edge Chamfer features with live previews
- Neutral-plane Draft features with selected taper faces and reversible pull direction
- Document-order feature replay after sketch, distance, angle, axis, or Boolean changes
- Selectable Solid Bodies folder and body nodes in the feature tree
- In-context sketch editing with surrounding bodies visible, a normal-to-support camera, and restoration of the previous 3D view on exit
- Intersection-aware trim for isolated line and circle segments, including circle/rectangle crossings
- Right-click feature-tree actions and dependency-aware deletion
- Orbit, pan, zoom, and face selection
- Editable JSON project download
- Exact STEP export

Next: add a formal geometric constraint solver and advanced variable-radius, asymmetric, and parting-line feature variants.
