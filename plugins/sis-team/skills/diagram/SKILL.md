---
name: diagram
description: Draw or update an AWS architecture diagram of the ship-it-safely lab as an editable draw.io file with official AWS icons, exported to PNG, built from the real Terraform, workflows and ADRs. Use as /sis-team:diagram <topic>, e.g. "overview", "bootstrap", "ci-cd", "app-ecs".
argument-hint: <topic>
---

# /sis-team:diagram

Topic: `$ARGUMENTS` (ask if empty). Output, in `docs/diagrams/` (orchestrator-owned, ADR 0001 D14):

- `<topic>.drawio`: the source, editable in draw.io.
- `<topic>.drawio.png`: the export with the XML embedded, so the PNG also opens in draw.io.
- A row in `docs/diagrams/README.md` (diagram, what it shows, `Based on` commit, date), and a link from the
  README that documents that part (repo README, `infra/terraform/**/README.md`).

If `<topic>.drawio` exists, update it instead of starting over.

## 1. Facts first

Draw only what the repo says. Read, in this order, and note `file:line` for every box and arrow:

1. `infra/terraform/**` (resources, names from `locals.tf`, the `resource_names` output),
   `.github/workflows/*.yml` (jobs, `environment:`, which role each job assumes).
2. `docs/adr/*.md` and `docs/requirements.md` (Architecture) for the intended design.

Anything in the ADR or PLAN but not in code yet is **planned**: draw it with the planned edge/border style and
label it `(planned, Phase N)`. Never invent a service, name or flow. Use names (`sis-dev-gha-plan`), never
account IDs, ARNs with IDs, or emails (D2).

Pin the diagram to `git rev-parse --short HEAD` in the title block.

## 2. Layout

- One idea per page. `overview`: GitHub on the left, the AWS account on the right, request and deploy
  flows left to right. Split detail (IAM trust, network) into extra pages of the same file, not one crowded page.
- Nesting: AWS Cloud > AWS account > VPC > public subnet. Children use `parent="<group id>"` and coordinates
  relative to the group.
- Grid: icons on a 20px grid, at least 180px apart horizontally and 160px vertically, same spacing along a flow.
  A branch sits on its parent's centerline (`child.x = parent.x + parent.w/2 - child.w/2`).
- Edges: every edge has `source` and `target`; at most one bend; never through an unrelated icon; two edges
  never share a corridor. Edges between different groups use `parent="1"`.
- Labels: icon label = AWS name + resource name on two lines (`ECS service<br>sis-dev-app`); edge labels 1 to 3
  words, only when the flow is not obvious. When an edge enters an icon from below, put that icon's label on top
  (`verticalLabelPosition=top;verticalAlign=bottom;`) so the edge does not cut through it.
- Title block top-left: `<b>ship-it-safely: <topic></b><br>Based on <commit> | <date>`. A small legend for
  edge styles when more than one is used.

## 3. Icons and styles

Use only the names and style templates in [`references/icons.md`](references/icons.md). Every name there was
rendered and checked. Need another icon? Render it alone first (step 4), look at the PNG, then add it to
`icons.md`.

## 4. Check, export, look

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/diagram/scripts/check_drawio.py" docs/diagrams/<topic>.drawio
```

```bash
drawio -x -f png -e -s 2 -b 20 -o docs/diagrams/<topic>.drawio.png docs/diagrams/<topic>.drawio
```

- `check_drawio.py` must print nothing. It checks well-formed XML without comments, unique ids, attached edges,
  group containers, icon names against `icons.md`, and no account ID or email.
- `drawio` is draw.io Desktop's CLI (`brew install --cask drawio`); on macOS without the link use
  `/Applications/draw.io.app/Contents/MacOS/draw.io`. If it is missing, stop after the `.drawio` file and tell
  the user the export command.
- **Read the PNG** and check: no blank or wrong icons, no edge through an icon, no overlapping labels, groups
  contain their children. Fix the coordinates and re-export until it is clean.

## 5. Report

Show the PNG path, list what is drawn as existing vs planned with the `file:line` sources, and say what you
left out on purpose. Commit only if the user asks (`docs(diagrams): ...`).
