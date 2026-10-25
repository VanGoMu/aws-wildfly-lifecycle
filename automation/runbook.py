"""aws:executeScript handlers of the Release and Switch runbooks (python3.12): plan only reads
and decides, shift_traffic is the only thing that moves the ALB, check_canary reads the metrics.
No double braces in this file: Automation would take them for variables of the runbook."""
import base64
import hashlib
import json
import re
from datetime import UTC, datetime

import boto3
from botocore.config import Config

RETRIES = Config(retries={"mode": "standard", "max_attempts": 5})  # executeScript has none
s3, ssm, ec2, elb, cw, sm, cd = (boto3.client(name, config=RETRIES) for name in (
    "s3", "ssm", "ec2", "elbv2", "cloudwatch", "secretsmanager", "codedeploy"))
OTHER = {"blue": "green", "green": "blue"}
V = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?"
KEYS = re.compile(r"^(releases/(?P<app>[a-z][a-z0-9-]+)/(?P<v>" + V + r")/(?P=app)-(?P=v)"
                  r"|config-releases/wildfly-config/(?P<c>" + V + r")/wildfly-config-(?P=c))\.zip$")


def param(e, name, default):
    try:
        return ssm.get_parameter(Name=f"{e['ParameterRoot']}/{name}")["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        return default


def context(e):  # …/infra/alb ({} without ALB) and the running instance of each color
    filters = [{"Name": f"tag:{k}", "Values": [e[k]]} for k in ("Project", "Environment")]
    filters.append({"Name": "instance-state-name", "Values": ["running"]})
    found = {}
    for r in ec2.describe_instances(Filters=filters)["Reservations"]:
        for i in r["Instances"]:
            color = {t["Key"]: t["Value"] for t in i["Tags"]}.get("Color")
            found.setdefault(color, i["InstanceId"])
    return json.loads(param(e, "infra/alb", "{}")), found


def state(e, color):  # what IS on a color: a rollback only moves the pointer and the weights
    return {k: json.loads(param(e, f"state/{color}/{k}", "{}")) for k in ("release", "config")}


def active_color(e, infra, warnings):  # the heaviest target group: console changes count
    pointer = param(e, "state/active-color", "blue")
    if not infra:
        return pointer
    action = elb.describe_listeners(ListenerArns=[infra["productionListenerArn"]])
    groups = action["Listeners"][0]["DefaultActions"][0]["ForwardConfig"]["TargetGroups"]
    weight = {g["TargetGroupArn"]: g.get("Weight", 0) for g in groups}
    blue, green = (weight.get(infra["targetGroups"][c]["arn"], 0) for c in ("blue", "green"))
    active = pointer if blue == green else ("blue" if blue > green else "green")
    if active != pointer:
        warnings.append(f"the listener says {active}, active-color says {pointer}")
    return active


def verified(e, key, version_id=""):  # the key is the identity; tags are a checked mirror
    match = KEYS.match(key)
    if not match:
        raise ValueError(f"{key} is not a key of the contract")
    head = s3.head_object(Bucket=e["Bucket"], Key=key, ChecksumMode="ENABLED",
                          **({"VersionId": version_id} if version_id else {}))
    tags = {t["Key"]: t["Value"] for t in s3.get_object_tagging(
        Bucket=e["Bucket"], Key=key, VersionId=head["VersionId"])["TagSet"]}
    sha = base64.b64decode(head.get("ChecksumSHA256", "")).hex()
    problems = [why for ok, why in (  # a single PutObject is FULL_OBJECT; multipart, COMPOSITE
        (head.get("ChecksumType") == "FULL_OBJECT", "ChecksumType is not FULL_OBJECT"),
        (tags.get("Sha256") == sha, "the Sha256 tag is not the checksum of the object"),
        (tags.get("Version") == (match["v"] or match["c"]), "the Version tag is not the key's"),
    ) if not ok]
    if problems:
        raise ValueError(f"s3://{e['Bucket']}/{key}: {'; '.join(problems)}")
    return {"key": key, "versionId": head["VersionId"], "version": tags["Version"],
            "sha256": sha, "eTag": head["ETag"].strip('"')}


def fingerprint(e, sha):  # release bytes + sorted name=value + AWSCURRENT version, no value
    path = f"{e['ParameterRoot']}/config"
    pages = ssm.get_paginator("get_parameters_by_path").paginate(Path=path, Recursive=True)
    pairs = sorted(f"{p['Name'][len(path) + 1:]}={p['Value']}"
                   for page in pages for p in page["Parameters"])
    try:
        stages = sm.describe_secret(SecretId=e["SecretId"]).get("VersionIdsToStages", {})
        secret = next((v for v, s in stages.items() if "AWSCURRENT" in s), "none")
    except sm.exceptions.ResourceNotFoundException:
        secret = "none"
    return hashlib.sha256("\n".join([sha, *pairs, secret]).encode()).hexdigest()


def plan(e, ctx):
    (infra, instances), warnings = context(e), []
    active = active_color(e, infra, warnings)
    target = e["TargetColor"] or OTHER[active]
    if not e["TargetColor"] and target not in instances:
        target = active
        warnings.append(f"no {OTHER[active]} instance: in place on {active}, without canary")
    if target not in instances:
        raise ValueError(f"no running instance with Color={target}")
    if e.get("Mode") == "switch":
        return {"TargetInstanceId": instances[target], "HasAlb": bool(infra),
                "TargetGroupArn": infra.get("targetGroups", {}).get(target, {}).get("arn", "none")}
    group = f"{e['Prefix']}-{target}"
    if cd.list_deployments(applicationName=e["Prefix"], deploymentGroupName=group,
                           includeOnlyStatuses=["Created", "Queued", "InProgress"])["deployments"]:
        raise ValueError(f"CodeDeploy is still deploying or rolling back on {target}")
    live, have = state(e, active), state(e, target)
    key = e["RevisionKey"] or live["release"].get("key", "")
    vid = e["RevisionVersionId"] if e["RevisionKey"] else live["release"].get("versionId", "")
    rel = verified(e, key, vid) if key else {}
    version = e["ConfigVersion"] or live["config"].get("version", "")
    ckey = f"config-releases/wildfly-config/{version}/wildfly-config-{version}.zip"
    cfg = {"version": version, "fingerprint": fingerprint(e, verified(e, ckey)["sha256"])} \
        if version else {}
    # A duplicated event after the switch: production already runs exactly this.
    skip = str(e["Promote"]).lower() == "true" and (live["release"].get("versionId"),
           live["config"].get("fingerprint")) == (rel.get("versionId"), cfg.get("fingerprint"))
    weight = int(e["CanaryWeight"]) if infra and live["release"] and target != active else 0
    return {
        "TargetColor": target, "ActiveColor": active, "TargetInstanceId": instances[target],
        "TargetDeploymentGroup": group, "HasAlb": bool(infra), "Skip": skip,
        "ConfigChanged": bool(cfg) and have["config"].get("fingerprint") != cfg["fingerprint"],
        "RevisionChanged": bool(rel) and have["release"].get("versionId") != rel["versionId"],
        "CanaryWeight": weight, "ConfigSourceInfo": json.dumps(
            {"path": f"https://{e['Bucket']}.s3.{e['Region']}.amazonaws.com/{ckey}"}),
        "ExtraVariables": f"config_path={e['ParameterRoot']}/config config_version={version}"
                          f" fingerprint={cfg.get('fingerprint', 'none')}",
        "RevisionBucket": e["Bucket"], "RevisionKey": rel.get("key", "none"),
        "RevisionVersion": rel.get("versionId", "none"), "RevisionETag": rel.get("eTag", "none"),
        "TargetConfigState": json.dumps(cfg or have["config"]),
        "TargetReleaseState": json.dumps({k: v for k, v in rel.items() if k != "eTag"}
                                         if rel else have["release"]),
        "Warnings": "; ".join(warnings) or "none"}


def shift_traffic(e, ctx):
    """Relative weights: target = Weight, the other = 100 - Weight. The test listener stays on
    the target until it gets everything, then goes to the other color."""
    infra, target, weight = context(e)[0], e["Target"], int(e["Weight"])
    if infra:
        tgs = infra["targetGroups"]
        elb.modify_listener(ListenerArn=infra["productionListenerArn"], DefaultActions=[{
            "Type": "forward", "ForwardConfig": {"TargetGroups": [
                {"TargetGroupArn": tgs[target]["arn"], "Weight": weight},
                {"TargetGroupArn": tgs[OTHER[target]]["arn"], "Weight": 100 - weight}],
                "TargetGroupStickinessConfig": {"Enabled": False}}}])
        test = target if weight < 100 else OTHER[target]
        elb.modify_listener(ListenerArn=infra["testListenerArn"], DefaultActions=[
            {"Type": "forward", "TargetGroupArn": tgs[test]["arn"]}])
    return {"StartTime": datetime.now(UTC).isoformat(timespec="seconds")}


def check_canary(e, ctx):
    """The exact window, from the weight change on. Not an alarm: its sliding window could take
    in the seconds of the deployment, when the target group was not healthy yet."""
    infra = context(e)[0]
    dims = [{"Name": "LoadBalancer", "Value": infra["loadBalancer"]},
            {"Name": "TargetGroup", "Value": infra["targetGroups"][e["Target"]]["dimension"]}]
    queries = [{"Id": i, "MetricStat": {"Metric": {"Namespace": "AWS/ApplicationELB",
                "MetricName": name, "Dimensions": dims}, "Period": 60, "Stat": stat}}
               for i, name, stat in (("errors", "HTTPCode_Target_5XX_Count", "Sum"),
                                     ("unhealthy", "UnHealthyHostCount", "Maximum"),
                                     ("requests", "RequestCount", "Sum"))]
    data = cw.get_metric_data(MetricDataQueries=queries, StartTime=datetime.fromisoformat(
        e["Start"]), EndTime=datetime.now(UTC))["MetricDataResults"]
    seen = {r["Id"]: (max if r["Id"] == "unhealthy" else sum)(r["Values"] or [0]) for r in data}
    if seen["errors"] or seen["unhealthy"] or seen["requests"] < int(e["MinRequests"]):
        raise RuntimeError(f"canary on {e['Target']} failed: {seen}")
    return {"Errors5xx": seen["errors"], "Unhealthy": seen["unhealthy"],
            "Requests": seen["requests"]}
