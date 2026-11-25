from pathlib import Path

import pytest

from lisa import LisaError
from lisa.paths import REPO
from lisa.settings import Settings, read_env_file


def write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "site.env"
    p.write_text(text)
    return p


def test_reads_values_as_bash_would(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", "/home/me")
    p = write(tmp_path, """
# a comment
HPC_PROJECT_ROOT=/home/x/lisa          # a comment after the value
SSH_KEY=$HOME/.ssh/id_ed25519
SOCK=${HPC_PROJECT_ROOT}/sock
IMAGES="alpine:3.20 busybox:1.37"
EMPTY=
""")
    v = read_env_file(p)
    assert v == {"HPC_PROJECT_ROOT": "/home/x/lisa", "SSH_KEY": "/home/me/.ssh/id_ed25519",
                 "SOCK": "/home/x/lisa/sock", "IMAGES": "alpine:3.20 busybox:1.37", "EMPTY": ""}


def test_a_line_that_is_not_key_value_is_an_error(tmp_path):
    with pytest.raises(LisaError, match="line 1"):
        read_env_file(write(tmp_path, "this is not a setting\n"))


def test_examples_load_and_say_what_is_missing():
    d = Settings.load(REPO / "settings" / "deucalion.env.example")
    assert set(d.missing) == {"HPC_PROJECT_ROOT", "GS_ACCESS_KEY", "GS_SECRET_KEY"}
    assert d.unknown == ()
    assert d.image_mirror is False          # experimental: off unless asked for
    t = Settings.load(REPO / "settings" / "testbed.env.example")
    assert t.missing == () and t.unknown == ()


def test_forwards_name_the_global_storage_the_api_and_the_mirror_when_on(tmp_path):
    base = "ARGO_NAMESPACE=ns\nGS_ENDPOINT=cluster\nEXTRA_FORWARDS=\"nats.ns.svc.cluster.local:4222\"\n"
    off = Settings.load(write(tmp_path, base))
    assert off.forwards == ["global-storage.ns.svc.cluster.local:9000",
                            "6443:kubernetes.default.svc.cluster.local:443", "nats.ns.svc.cluster.local:4222"]
    on = Settings.load(write(tmp_path, base + "IMAGE_MIRROR=on\n"))
    assert "image-mirror.ns.svc.cluster.local:5000" in on.forwards


def test_external_global_storage_port(tmp_path):
    s = Settings.load(write(tmp_path, "GS_ENDPOINT=192.168.104.4:9000\n"))
    assert (s.gs_in_cluster, s.gs_host, s.gs_port) == (False, "192.168.104.4", 9000)


def test_keys_of_older_versions_are_reported_not_fatal(tmp_path):
    s = Settings.load(write(tmp_path, "HPC_REPO_DIR=/x\nSPLIT_API=1\n"))
    assert s.unknown == ("HPC_REPO_DIR", "SPLIT_API")


def test_require_stops_on_a_relative_project_root(tmp_path):
    s = Settings.load(REPO / "settings" / "testbed.env.example")
    s.require()
    bad = Settings.load(write(tmp_path, (REPO / "settings/testbed.env.example").read_text()
                              .replace("HPC_PROJECT_ROOT=/", "HPC_PROJECT_ROOT=")))
    with pytest.raises(LisaError, match="absolute"):
        bad.require()
