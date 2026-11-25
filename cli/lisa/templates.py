"""Templates filled in from the settings: the runner's files (runner/) and the tool's own manifests
(cli/manifests/), each named by its path from the repository's root.

A template names its values as ${name}; every name must be given (a missing one is an error, so a
typo cannot leave a placeholder in what gets installed). YAML templates come back as data, so the
code can add what depends on a setting (e.g. the image mirror) in plain sight, and so a template that
is not valid YAML fails here rather than in the cluster.
"""
from string import Template

import yaml

from . import LisaError
from .paths import REPO


def render_text(relpath: str, **values) -> str:
    text = (REPO / relpath).read_text()
    try:
        return Template(text).substitute(**{k: str(v) for k, v in values.items()})
    except KeyError as e:
        raise LisaError(f"{relpath} needs a value for {e}") from None


def render_yaml(relpath: str, **values) -> list[dict]:
    """All the YAML documents of a template, filled in."""
    return [d for d in yaml.safe_load_all(render_text(relpath, **values)) if d]


def render_one(relpath: str, **values) -> dict:
    (doc,) = render_yaml(relpath, **values)
    return doc


def to_yaml(data) -> str:
    return yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
