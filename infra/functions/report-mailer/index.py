import logging
import os
import urllib.parse
from email.message import EmailMessage

import boto3

log = logging.getLogger("report-mailer")
log.setLevel(logging.INFO)
s3 = boto3.client("s3")
ses = boto3.client("sesv2")


def handler(event, context):
    recipients = [a.strip() for a in os.environ["RECIPIENTS"].split(",") if a.strip()]
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        # Keys arrive URL-encoded in S3 events ("a b.csv" -> "a+b.csv").
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        log.info(
            "report-mailer triggered",
            extra={
                "trigger": "s3" if record.get("eventSource") == "aws:s3" else "direct",
                "event": record.get("eventName"),
                "bucket": bucket,
                "key": key,
            },
        )
        report = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        week = key.rsplit("/", 1)[-1].removesuffix(".csv")

        msg = EmailMessage()
        msg["Subject"] = f"Weekly meetings report {week}"
        msg["From"] = os.environ["SENDER"]
        msg["To"] = ", ".join(recipients)
        msg.set_content(
            f"Hello,\n\nThe meetings report for {week} is attached.\n\n"
            f"It is kept in s3://{bucket}/{key} for 90 days.\n"
        )
        msg.add_attachment(
            report, maintype="text", subtype="csv", filename=f"meetings-{week}.csv"
        )
        sent = ses.send_email(
            FromEmailAddress=os.environ["SENDER"],
            Destination={"ToAddresses": recipients},
            Content={"Raw": {"Data": msg.as_bytes()}},
        )
        log.info(
            "report emailed",
            extra={"key": key, "recipients": recipients, "message_id": sent["MessageId"]},
        )
