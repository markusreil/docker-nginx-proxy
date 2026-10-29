# Robot acceptance suite: proxy http/https/cert/no-cert matrix.
#
# Isolated stack (own compose project, network, volumes, host ports 18080 /
# 18443) — safe to run next to the real proxy, which keeps 80/443.
# Only needs the `robot` binary (pipx) and `curl`; HTTP is driven through
# the Process library, no extra Robot libraries required.
#
# Run:
#     cd test && robot --outputdir out proxy.robot
#
# Artifacts (output.xml, report.html, proxy/backends compose logs) land in
# test/out/, which is gitignored.
