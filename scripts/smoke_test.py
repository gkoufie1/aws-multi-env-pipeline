#!/usr/bin/env python3
"""
Post-apply smoke test for the vpc-baseline module.

Terraform succeeding means AWS accepted the API calls, not that the
resulting infrastructure is actually correct. This checks the *live*
resources against what the environment is supposed to look like, using
the same terraform outputs the CI pipeline already has on hand.

Usage:
    python scripts/smoke_test.py --outputs outputs.json --environment dev
"""

import argparse
import json
import sys

import boto3

EXPECTED_SUBNET_COUNT = 2

CIDR_BY_ENV = {
    "dev": "10.10.0.0/16",
    "staging": "10.20.0.0/16",
    "prod": "10.30.0.0/16",
}


class Check:
    def __init__(self, name):
        self.name = name
        self.passed = True
        self.details = []

    def fail(self, message):
        self.passed = False
        self.details.append(message)

    def ok(self, message):
        self.details.append(message)


def load_outputs(path):
    with open(path) as f:
        raw = json.load(f)
    # terraform output -json wraps each value as {"value": ...}
    return {k: v["value"] for k, v in raw.items()}


def check_vpc(ec2, outputs, environment, results):
    check = Check("VPC")
    vpc_id = outputs["vpc_id"]
    resp = ec2.describe_vpcs(VpcIds=[vpc_id])
    vpcs = resp["Vpcs"]

    if not vpcs:
        check.fail(f"VPC {vpc_id} does not exist")
        results.append(check)
        return

    vpc = vpcs[0]
    expected_cidr = CIDR_BY_ENV[environment]
    if vpc["CidrBlock"] != expected_cidr:
        check.fail(f"CIDR is {vpc['CidrBlock']}, expected {expected_cidr}")
    else:
        check.ok(f"CIDR matches ({expected_cidr})")

    tags = {t["Key"]: t["Value"] for t in vpc.get("Tags", [])}
    if tags.get("Environment") != environment:
        check.fail(f"Environment tag is {tags.get('Environment')!r}, expected {environment!r}")
    else:
        check.ok("Environment tag correct")

    results.append(check)


def check_subnets(ec2, outputs, results):
    check = Check("Subnets")
    public_ids = outputs["public_subnet_ids"]
    private_ids = outputs["private_subnet_ids"]

    if len(public_ids) != EXPECTED_SUBNET_COUNT:
        check.fail(f"{len(public_ids)} public subnets, expected {EXPECTED_SUBNET_COUNT}")
    else:
        check.ok(f"{EXPECTED_SUBNET_COUNT} public subnets present")

    if len(private_ids) != EXPECTED_SUBNET_COUNT:
        check.fail(f"{len(private_ids)} private subnets, expected {EXPECTED_SUBNET_COUNT}")
    else:
        check.ok(f"{EXPECTED_SUBNET_COUNT} private subnets present")

    resp = ec2.describe_subnets(SubnetIds=public_ids + private_ids)
    by_id = {s["SubnetId"]: s for s in resp["Subnets"]}

    for sid in public_ids:
        subnet = by_id.get(sid)
        if subnet is None:
            check.fail(f"public subnet {sid} not found")
        elif not subnet["MapPublicIpOnLaunch"]:
            check.fail(f"public subnet {sid} does not auto-assign public IPs")

    for sid in private_ids:
        subnet = by_id.get(sid)
        if subnet is None:
            check.fail(f"private subnet {sid} not found")
        elif subnet["MapPublicIpOnLaunch"]:
            check.fail(f"private subnet {sid} auto-assigns public IPs (should be private)")

    results.append(check)


def check_security_group(ec2, outputs, results):
    check = Check("Security Group")
    sg_id = outputs["security_group_id"]
    resp = ec2.describe_security_groups(GroupIds=[sg_id])
    groups = resp["SecurityGroups"]

    if not groups:
        check.fail(f"security group {sg_id} does not exist")
        results.append(check)
        return

    sg = groups[0]
    if sg["IpPermissions"]:
        check.fail(f"baseline SG has {len(sg['IpPermissions'])} ingress rule(s), expected 0 — "
                    "this SG should never have inbound access, app-specific SGs should be separate resources")
    else:
        check.ok("no ingress rules (as intended)")

    egress = sg["IpPermissionsEgress"]
    https_only = (
        len(egress) == 1
        and egress[0].get("FromPort") == 443
        and egress[0].get("ToPort") == 443
    )
    if not https_only:
        check.fail(f"egress rules are {egress!r}, expected HTTPS-only (443)")
    else:
        check.ok("egress restricted to HTTPS (443)")

    results.append(check)


def check_s3_bucket(s3, outputs, results):
    check = Check("S3 Bucket")
    bucket = outputs["s3_bucket_name"]

    try:
        s3.head_bucket(Bucket=bucket)
    except Exception as e:
        check.fail(f"bucket {bucket} not reachable: {e}")
        results.append(check)
        return

    pab = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    if not all(pab.values()):
        check.fail(f"public access block not fully enabled: {pab}")
    else:
        check.ok("public access fully blocked")

    versioning = s3.get_bucket_versioning(Bucket=bucket)
    if versioning.get("Status") != "Enabled":
        check.fail(f"versioning is {versioning.get('Status')!r}, expected 'Enabled'")
    else:
        check.ok("versioning enabled")

    try:
        enc = s3.get_bucket_encryption(Bucket=bucket)
        rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
        algo = rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"]
        if algo != "AES256":
            check.fail(f"encryption algorithm is {algo}, expected AES256")
        else:
            check.ok("default encryption (AES256) configured")
    except Exception as e:
        check.fail(f"no encryption configuration found: {e}")

    results.append(check)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--outputs", required=True, help="Path to terraform output -json file")
    parser.add_argument("--environment", required=True, choices=["dev", "staging", "prod"])
    args = parser.parse_args()

    outputs = load_outputs(args.outputs)
    ec2 = boto3.client("ec2", region_name="us-east-1")
    s3 = boto3.client("s3", region_name="us-east-1")

    results = []
    check_vpc(ec2, outputs, args.environment, results)
    check_subnets(ec2, outputs, results)
    check_security_group(ec2, outputs, results)
    check_s3_bucket(s3, outputs, results)

    print(f"\nSmoke test results — {args.environment}\n" + "=" * 40)
    all_passed = True
    for check in results:
        status = "PASS" if check.passed else "FAIL"
        if not check.passed:
            all_passed = False
        print(f"[{status}] {check.name}")
        for detail in check.details:
            print(f"    - {detail}")

    print("=" * 40)
    if not all_passed:
        print("SMOKE TEST FAILED — blocking promotion to the next environment")
        sys.exit(1)

    print("All checks passed")
    sys.exit(0)


if __name__ == "__main__":
    main()
