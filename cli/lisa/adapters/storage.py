"""The Global Storage (any S3 endpoint; a MinIO here), as the Kubernetes side reaches it."""
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

from .. import LisaError


class Storage:
    def __init__(self, endpoint: str, access_key: str, secret_key: str, insecure: bool, bucket: str):
        self.endpoint = endpoint
        self.bucket = bucket
        self._s3 = boto3.client(
            "s3", endpoint_url=("http://" if insecure else "https://") + endpoint,
            aws_access_key_id=access_key, aws_secret_access_key=secret_key, region_name="us-east-1",
            config=Config(connect_timeout=5, read_timeout=60, retries={"max_attempts": 2},
                          s3={"addressing_style": "path"}))

    def problem(self) -> str | None:
        """None when the endpoint answers and accepts the keys; otherwise what is wrong."""
        try:
            self._s3.list_buckets()
            return None
        except ClientError as e:
            return f"the Global Storage at {self.endpoint} refuses the keys: {e.response['Error']['Code']}"
        except BotoCoreError as e:
            return f"the Global Storage at {self.endpoint} does not answer: {e}"

    def bucket_exists(self, bucket: str | None = None) -> bool:
        try:
            self._s3.head_bucket(Bucket=bucket or self.bucket)
            return True
        except ClientError:
            return False

    def create_bucket(self, bucket: str | None = None) -> None:
        """The default bucket, or another one on the same endpoint."""
        if not self.bucket_exists(bucket):
            self._s3.create_bucket(Bucket=bucket or self.bucket)

    def delete_prefix(self, prefix: str) -> int:
        n = 0
        for page in self._s3.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix=prefix):
            keys = [{"Key": o["Key"]} for o in page.get("Contents", [])]
            if keys:
                self._s3.delete_objects(Bucket=self.bucket, Delete={"Objects": keys})
                n += len(keys)
        return n

    def upload(self, path: Path, key: str, bucket: str | None = None, metadata: dict | None = None) -> None:
        try:
            self._s3.upload_file(str(path), bucket or self.bucket, key,
                                 ExtraArgs={"Metadata": metadata} if metadata else None)
        except (BotoCoreError, ClientError) as e:
            raise LisaError(f"upload of {path} to {self.bucket}/{key} failed: {e}") from None

    def metadata(self, key: str, bucket: str | None = None) -> dict | None:
        """The object's user metadata, or None when there is no such object."""
        try:
            return self._s3.head_object(Bucket=bucket or self.bucket, Key=key).get("Metadata", {})
        except ClientError:
            return None

    def read_text(self, key: str) -> str | None:
        """The object's content, or None when there is no such object."""
        try:
            return self._s3.get_object(Bucket=self.bucket, Key=key)["Body"].read().decode(errors="replace")
        except ClientError as e:
            if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
                return None
            raise
