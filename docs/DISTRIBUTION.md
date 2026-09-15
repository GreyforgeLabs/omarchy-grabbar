# Directory distribution after a release

Directory submission is part of Grabbar's release workflow. The operator
requested this standing step on 2026-09-15. Carry an authorized release through
the applicable directory updates; announcements on social media are separate.

1. Verify the public release, manifest, license/credits, installation/removal
   instructions, dependencies, preview screenshot, and testing limitations.
   Finish and push listing-related repository changes before requesting a scan.
2. Check the current contribution rules and existing listing at the
   [official marketplace](https://plugins.omarchy.org/publish.html),
   [Okomart](https://github.com/brianblakely/omarchy-plugins#plugin-catalog),
   [Omarchy Hub](https://github.com/deepakness/omarchy-hub/blob/main/CONTRIBUTING.md),
   and [Awesome Omarchy](https://github.com/aorumbayev/awesome-omarchy/blob/main/CONTRIBUTING.md).
   Follow redirects and check eligibility before submitting. Catalog consumers
   do not need duplicate entries for the same upstream source.
3. Submit through each eligible target's documented issue or PR route. State
   that the native title strip needs an explicit build/load and disclose the
   current preview/full-login qualification boundary. Never imply marketplace
   approval or a security certification before it exists.
4. Preserve the release tag, exact submitted HEAD, posted body, receipt URL,
   initial validation, and next action. Keep mutable submission receipts outside
   the repository so recording them does not invalidate exact-commit scans.
5. On later releases, update existing listings using their current update or
   verification process. Report pending maintainer decisions and eligibility
   gates separately from successful publication.

Greyforge's shared `omarchy-plugin-distribution` skill maintains the practical
routing reference. Local submission receipts live under
`~/.local/state/greyforge/plugin-distribution/grabbar/`.
