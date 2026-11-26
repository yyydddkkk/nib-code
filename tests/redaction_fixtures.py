import hashlib

SYNTHETIC_TOKEN = "ghp_" + hashlib.sha256(b"nib synthetic redaction fixture").hexdigest()[:36]


def assert_no_token(test, *outputs):
    for output in outputs:
        for fragment in (SYNTHETIC_TOKEN, SYNTHETIC_TOKEN[:16], SYNTHETIC_TOKEN[-16:]):
            test.assertTrue(fragment not in output, "synthetic credential fragment leaked")
