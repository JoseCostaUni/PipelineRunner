"""Secrets blanked in evidence and diagnostics, whatever form interLink's logs give them."""
from lisa import redact
from lisa.paths import REPO
from lisa.settings import Settings


def settings(tmp_path):
    p = tmp_path / "s.env"
    p.write_text((REPO / "settings/testbed.env.example").read_text()
                 + "GS_ACCESS_KEY=lisa\nGS_SECRET_KEY=s3cr3t-value-123\nMIRROR_PRIVATE_TOKEN=glpat-example-xyz\n")
    return Settings.load(p)


def test_a_secret_in_a_pods_environment_is_blanked(tmp_path):
    """How it leaked (TC21, CNES's ingest): interLink logs a container's env, secretKeyRef resolved."""
    s = settings(tmp_path)
    line = ('time="2026-11-25T16:55:01Z" msg="pod" env=[{"name":"AWS_ACCESS_KEY_ID","value":"lisa"},'
            '{"name":"AWS_SECRET_ACCESS_KEY","value":"s3cr3t-value-123"}]')
    out = redact.text(line, s)
    assert "s3cr3t-value-123" not in out and '"value":"<redacted>"' in out
    assert '"value":"lisa"' in out                     # the access key is a user name, left alone


def test_secret_data_tokens_and_base64_forms_are_blanked(tmp_path):
    s = settings(tmp_path)
    line = ('"data":{"secretkey":"' + redact.b64("s3cr3t-value-123") + '"} token eyJhbGciOiJ.eyJzdWIi.sig '
            + redact.b64("lisa") + " glpat-example-xyz")
    out = redact.text(line, s)
    for secret in ("s3cr3t-value-123", redact.b64("s3cr3t-value-123"), redact.b64("lisa"), "eyJhbGciOi",
                   "glpat-example-xyz"):
        assert secret not in out
