import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LAB = Path(__file__).resolve().parents[1] / "lab.sh"
IDS = dict(zip(("jumpbox", "server", "node-0", "node-1"), ("i-01", "i-02", "i-03", "i-04")))
ACCOUNT = "123456789012"

AWS = """
import json, os, pathlib, sys
path = pathlib.Path(os.environ["TEST_STATE"])
state = json.loads(path.read_text())
args = sys.argv[5:]
with path.with_name("calls").open("a") as f:
    print(json.dumps(args), file=f)
assert sys.argv[1:5] == ["--profile", "kthw-instance-access", "--region", "us-east-1"]
if args[0] == "sts":
    print(os.environ["TEST_ACCOUNT"])
elif args[1] == "describe-instances" and args[-3] == "Reservations[0].Instances[0].State.Name":
    print(state[args[3]])
elif args[1] in ("start-instances", "stop-instances"):
    for instance in args[3:]:
        state[instance] = "running" if args[1] == "start-instances" else "stopped"
    path.write_text(json.dumps(state))
elif args[1] == "describe-instance-status":
    ids = args[3:args.index("--query")]
    assert all(state[instance] == "running" for instance in ids)
    initializing = path.with_name("initializing")
    if initializing.exists():
        initializing.unlink()
        print(len(ids) - 1)
    else:
        print(len(ids))
elif args[1] == "wait":
    for instance in args[4:]:
        assert state[instance] == args[2].removeprefix("instance-")
"""


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        self.state = self.path / "state"
        self.state.write_text(json.dumps(dict.fromkeys(IDS.values(), "stopped")))
        self.env = {
            **os.environ,
            "PATH": f"{self.path}:{os.environ['PATH']}",
            "TEST_ACCOUNT": ACCOUNT,
            "TEST_STATE": str(self.state),
            "TEST_OUTPUTS": json.dumps({
                "lab_account_id": {"value": ACCOUNT},
                "lab_region": {"value": "us-east-1"},
                "instance_ids": {"value": IDS},
            }),
            "TEST_PLAN": "{}",
        }
        self.fake("aws", AWS)
        self.fake("terraform", """
import os, pathlib, sys
command = sys.argv[1]
with pathlib.Path(os.environ["TEST_STATE"]).with_name("terraform_calls").open("a") as f:
    print(command, file=f)
if command == "output":
    print(os.environ["TEST_OUTPUTS"])
elif command == "show":
    print(os.environ["TEST_PLAN"])
""")

    def fake(self, name, body):
        executable = self.path / name
        executable.write_text(f"#!{sys.executable}\n{body}")
        executable.chmod(0o755)

    def lab(self, action, expected=0):
        result = subprocess.run([LAB, action], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def aws_calls(self):
        return [json.loads(line) for line in (self.path / "calls").read_text().splitlines()]

    def power_calls(self, action):
        return [args[3:] for args in self.aws_calls() if args[:2] == ["ec2", f"{action}-instances"]]

    def test_start_is_batched_and_stop_is_ordered_with_idempotent_retries(self):
        self.lab("start")
        self.lab("start")
        self.assertEqual(self.power_calls("start"), [list(IDS.values())])
        self.lab("stop")
        self.lab("stop")
        self.assertEqual(self.power_calls("stop"), [["i-03", "i-04"], ["i-02"], ["i-01"]])

    def test_missing_state_skips_aws(self):
        self.env["TEST_OUTPUTS"] = "{}"
        self.assertIn("no complete lab outputs", self.lab("status", expected=1).stderr)
        self.assertFalse((self.path / "calls").exists())

    def test_wrong_account_skips_ec2(self):
        self.env["TEST_ACCOUNT"] = "999999999999"
        self.assertIn("Account mismatch", self.lab("stop", expected=1).stderr)
        self.assertEqual(len((self.path / "calls").read_text().splitlines()), 1)

    def test_start_waits_for_every_instance_to_pass_health_checks(self):
        (self.path / "initializing").touch()
        self.fake("sleep", 'import sys\nassert sys.argv[1:] == ["15"]')
        self.lab("start")
        commands = self.aws_calls()
        polls = [args[3:args.index("--query")] for args in commands
                 if args[:2] == ["ec2", "describe-instance-status"]]
        self.assertEqual(polls, [list(IDS.values())] * 2)
        self.assertEqual(commands[-2][:2], ["ec2", "describe-instance-status"])

    def test_up_rejects_replacement_before_apply(self):
        self.env["TEST_PLAN"] = json.dumps({"resource_changes": [{
            "address": 'aws_instance.machine["server"]',
            "type": "aws_instance",
            "change": {"actions": ["delete", "create"]},
        }]})
        self.assertIn("refusing make up", self.lab("up", expected=1).stderr.lower())
        self.assertEqual((self.path / "terraform_calls").read_text().splitlines(), ["init", "plan", "show"])
        self.assertFalse((self.path / "calls").exists())

    def test_up_allows_removing_network_rules(self):
        self.env["TEST_PLAN"] = json.dumps({"resource_changes": [{
            "address": 'aws_security_group_rule.public_web["80"]',
            "type": "aws_security_group_rule",
            "change": {"actions": ["delete"]},
        }]})
        self.lab("up")
        self.assertEqual((self.path / "terraform_calls").read_text().splitlines(),
                         ["init", "plan", "show", "apply", "output"])
        self.assertEqual(self.power_calls("start"), [list(IDS.values())])


if __name__ == "__main__":
    unittest.main()
