import json
import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List

import azure.functions as func
from azure.core import MatchConditions
from azure.core.exceptions import (
    HttpResponseError,
    ResourceExistsError,
    ResourceNotFoundError,
)
from azure.data.tables import TableServiceClient, UpdateMode
from azure.identity import DefaultAzureCredential

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


def positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
        return value if value > 0 else default
    except ValueError:
        return default


WRITE_LIMIT_PER_HOUR = positive_int_env("WRITE_LIMIT_PER_HOUR", 30)
MAX_REQUEST_BYTES = positive_int_env("MAX_REQUEST_BYTES", 8 * 1024)
MAX_TITLE_LENGTH = positive_int_env("MAX_TITLE_LENGTH", 100)
MAX_SERVICE_LENGTH = positive_int_env("MAX_SERVICE_LENGTH", 80)
MAX_DESCRIPTION_LENGTH = positive_int_env("MAX_DESCRIPTION_LENGTH", 1000)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def cors_headers() -> Dict[str, str]:
    return {
        "Content-Type": "application/json; charset=utf-8",
        "Access-Control-Allow-Origin": os.getenv("CORS_ALLOWED_ORIGIN", "*"),
        "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type,Authorization",
        "Access-Control-Expose-Headers": (
            "X-RateLimit-Limit,X-RateLimit-Remaining,Retry-After"
        ),
    }


def json_response(
    payload: Any,
    status_code: int = 200,
    extra_headers: Dict[str, str] | None = None,
) -> func.HttpResponse:
    headers = cors_headers()

    if extra_headers:
        headers.update(extra_headers)

    return func.HttpResponse(
        body=json.dumps(payload, ensure_ascii=False, default=str),
        status_code=status_code,
        headers=headers,
        mimetype="application/json",
    )


def get_table_client(table_name: str):
    account_name = os.getenv("APP_STORAGE_ACCOUNT_NAME")

    if not account_name:
        raise RuntimeError("APP_STORAGE_ACCOUNT_NAME is not configured.")

    endpoint = f"https://{account_name}.table.core.windows.net"
    credential = DefaultAzureCredential()
    service = TableServiceClient(endpoint=endpoint, credential=credential)

    return service.get_table_client(table_name=table_name)


def get_incidents_table_client():
    return get_table_client(
        os.getenv("INCIDENTS_TABLE_NAME", "incidents")
    )


def get_rate_limits_table_client():
    return get_table_client(
        os.getenv("RATE_LIMITS_TABLE_NAME", "ratelimits")
    )


def normalize_entity(entity: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": entity.get("RowKey"),
        "title": entity.get("Title"),
        "service": entity.get("Service"),
        "severity": entity.get("Severity"),
        "status": entity.get("Status"),
        "description": entity.get("Description"),
        "createdAt": entity.get("CreatedAt"),
        "updatedAt": entity.get("UpdatedAt"),
    }


def parse_json_object(
    req: func.HttpRequest,
) -> tuple[Dict[str, Any] | None, func.HttpResponse | None]:
    body = req.get_body()

    if len(body) > MAX_REQUEST_BYTES:
        return None, json_response(
            {
                "error": "Request body too large.",
                "maxBytes": MAX_REQUEST_BYTES,
            },
            413,
        )

    if not body:
        return None, json_response(
            {"error": "Request body must contain JSON."},
            400,
        )

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, json_response(
            {"error": "Request body must be valid JSON."},
            400,
        )

    if not isinstance(payload, dict):
        return None, json_response(
            {"error": "Request body must be a JSON object."},
            400,
        )

    return payload, None


def validate_incident_payload(payload: Dict[str, Any]) -> List[str]:
    errors: List[str] = []

    title = str(payload.get("title", "")).strip()
    service = str(payload.get("service", "")).strip()
    description = str(payload.get("description", "")).strip()

    if not title:
        errors.append("title is required")
    elif len(title) > MAX_TITLE_LENGTH:
        errors.append(
            f"title must not exceed {MAX_TITLE_LENGTH} characters"
        )

    if not service:
        errors.append("service is required")
    elif len(service) > MAX_SERVICE_LENGTH:
        errors.append(
            f"service must not exceed {MAX_SERVICE_LENGTH} characters"
        )

    if len(description) > MAX_DESCRIPTION_LENGTH:
        errors.append(
            f"description must not exceed {MAX_DESCRIPTION_LENGTH} characters"
        )

    severity = str(payload.get("severity", "medium")).lower()
    if severity not in {"low", "medium", "high", "critical"}:
        errors.append(
            "severity must be low, medium, high or critical"
        )

    return errors


def seconds_until_next_utc_hour(now: datetime) -> int:
    elapsed = (now.minute * 60) + now.second
    return max(1, 3600 - elapsed)


def consume_write_quota() -> tuple[bool, int, int]:
    """
    Atomically consume one write from the global hourly demo quota.

    Azure Table Storage ETags are used for optimistic concurrency so that
    multiple Function instances share one global counter.
    """
    table = get_rate_limits_table_client()
    now = datetime.now(timezone.utc)

    bucket = now.strftime("%Y%m%d%H")
    retry_after = seconds_until_next_utc_hour(now)

    partition_key = "WRITE_QUOTA"
    row_key = bucket

    # Retries handle concurrent writes from multiple Function instances.
    for _ in range(10):
        try:
            entity = table.get_entity(
                partition_key=partition_key,
                row_key=row_key,
            )

        except ResourceNotFoundError:
            try:
                table.create_entity(
                    entity={
                        "PartitionKey": partition_key,
                        "RowKey": row_key,
                        "Count": 1,
                        "CreatedAt": utc_now_iso(),
                        "UpdatedAt": utc_now_iso(),
                    }
                )

                return (
                    True,
                    max(0, WRITE_LIMIT_PER_HOUR - 1),
                    retry_after,
                )

            except ResourceExistsError:
                # Another Function instance created the bucket first.
                continue

        current_count = int(entity.get("Count", 0))

        if current_count >= WRITE_LIMIT_PER_HOUR:
            return False, 0, retry_after

        updated = dict(entity)
        updated["Count"] = current_count + 1
        updated["UpdatedAt"] = utc_now_iso()

        etag = entity.metadata.get("etag")
        if not etag:
            raise RuntimeError(
                "Rate-limit entity did not contain an ETag."
            )

        try:
            table.update_entity(
                entity=updated,
                mode=UpdateMode.REPLACE,
                etag=etag,
                match_condition=MatchConditions.IfNotModified,
            )

            return (
                True,
                max(0, WRITE_LIMIT_PER_HOUR - current_count - 1),
                retry_after,
            )

        except HttpResponseError as exc:
            # 409/412 means another Function instance changed the counter.
            if exc.status_code in {409, 412}:
                continue

            raise

    raise RuntimeError(
        "Unable to update write quota after concurrent retries."
    )


def quota_headers(remaining: int) -> Dict[str, str]:
    return {
        "X-RateLimit-Limit": str(WRITE_LIMIT_PER_HOUR),
        "X-RateLimit-Remaining": str(remaining),
    }


def enforce_write_quota() -> tuple[
    func.HttpResponse | None,
    Dict[str, str],
]:
    allowed, remaining, retry_after = consume_write_quota()

    headers = quota_headers(remaining)

    if allowed:
        return None, headers

    headers["Retry-After"] = str(retry_after)

    return (
        json_response(
            {
                "error": "Public demo write limit reached.",
                "message": (
                    "Please try again after the hourly demo quota resets."
                ),
                "retryAfterSeconds": retry_after,
            },
            429,
            extra_headers=headers,
        ),
        headers,
    )


@app.route(route="health", methods=["GET", "OPTIONS"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return json_response({}, 204)

    return json_response(
        {
            "status": "healthy",
            "service": "azure-cloudops-api",
            "timestamp": utc_now_iso(),
        }
    )


@app.route(route="incidents", methods=["GET", "POST", "OPTIONS"])
def incidents(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return json_response({}, 204)

    try:
        table = get_incidents_table_client()

        if req.method == "GET":
            rows = [
                normalize_entity(dict(entity))
                for entity in table.list_entities()
            ]

            rows.sort(
                key=lambda item: item.get("createdAt") or "",
                reverse=True,
            )

            return json_response(
                {
                    "items": rows,
                    "count": len(rows),
                }
            )

        payload, error_response = parse_json_object(req)

        if error_response:
            return error_response

        errors = validate_incident_payload(payload)
        if errors:
            return json_response(
                {
                    "error": "Validation failed.",
                    "details": errors,
                },
                400,
            )

        quota_response, headers = enforce_write_quota()
        if quota_response:
            return quota_response

        now = utc_now_iso()

        incident_id = (
            f"INC-"
            f"{datetime.now(timezone.utc).strftime('%Y%m%d')}-"
            f"{uuid.uuid4().hex[:6].upper()}"
        )

        entity = {
            "PartitionKey": "INCIDENT",
            "RowKey": incident_id,
            "Title": str(payload["title"]).strip(),
            "Service": str(payload["service"]).strip(),
            "Severity": str(
                payload.get("severity", "medium")
            ).lower(),
            "Status": "open",
            "Description": str(
                payload.get("description", "")
            ).strip(),
            "CreatedAt": now,
            "UpdatedAt": now,
        }

        table.create_entity(entity=entity)

        logging.info("Created incident %s", incident_id)

        return json_response(
            normalize_entity(entity),
            201,
            extra_headers=headers,
        )

    except Exception:
        logging.exception("Incident endpoint failed")

        return json_response(
            {"error": "Internal server error."},
            500,
        )


@app.route(
    route="incidents/{incident_id}",
    methods=["GET", "PUT", "OPTIONS"],
)
def incident_by_id(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return json_response({}, 204)

    incident_id = req.route_params.get("incident_id")

    if not incident_id:
        return json_response(
            {"error": "incident_id is required"},
            400,
        )

    try:
        table = get_incidents_table_client()

        if req.method == "GET":
            entity = table.get_entity(
                partition_key="INCIDENT",
                row_key=incident_id,
            )

            return json_response(
                normalize_entity(dict(entity))
            )

        payload, error_response = parse_json_object(req)

        if error_response:
            return error_response

        allowed_statuses = {
            "open",
            "investigating",
            "resolved",
            "closed",
        }

        status = str(payload.get("status", "")).lower()

        if status not in allowed_statuses:
            return json_response(
                {
                    "error": (
                        "status must be open, investigating, "
                        "resolved or closed"
                    )
                },
                400,
            )

        quota_response, headers = enforce_write_quota()
        if quota_response:
            return quota_response

        entity = {
            "PartitionKey": "INCIDENT",
            "RowKey": incident_id,
            "Status": status,
            "UpdatedAt": utc_now_iso(),
        }

        table.update_entity(
            entity=entity,
            mode=UpdateMode.MERGE,
        )

        updated = table.get_entity(
            partition_key="INCIDENT",
            row_key=incident_id,
        )

        logging.info(
            "Updated incident %s to %s",
            incident_id,
            status,
        )

        return json_response(
            normalize_entity(dict(updated)),
            extra_headers=headers,
        )

    except ResourceNotFoundError:
        return json_response(
            {"error": "Incident not found."},
            404,
        )

    except Exception:
        logging.exception("Incident-by-id endpoint failed")

        return json_response(
            {"error": "Internal server error."},
            500,
        )
