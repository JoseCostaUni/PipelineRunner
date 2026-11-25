"""lisa: deploys and runs the LISA pipeline runner (plain Argo workflows on offline HPC compute nodes,
through interLink 0.6.3 and its reverse tunnel) from the Kubernetes side, as your own user.

What gets installed lives in runner/ at the repository root; this package only puts it in place,
checks it and runs the tests. docs/architecture.md explains the whole.
"""


class LisaError(Exception):
    """A failure the user can act on: printed as 'ERROR: <message>', exit status 1."""
