import json
import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List

import azure.functions as func
from azure.core.exceptions import ResourceNotFoundError
from azure.data.tables import TableServiceClient, UpdateMode
from azure.identity import DefaultAzureCredential

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def cors_headers() -> Dict[str, str]:
    return {
        "Content-Type": "application/json; charset=utf-8",
        "Access-Control-Allow-Origin": os.getenv("CORS_ALLOWED_ORIGIN", "*"),
        "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type,Authorization",
    }


def json_response(payload: Any, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        body=json.dumps(payload, ensure_ascii=False, default=str),
        status_code=status_code,
        headers=cors_headers(),
        mimetype="application/json",
    )


def get_table_client():
    account_name = os.getenv("APP_STORAGE_ACCOUNT_NAME")
    table_name = os.getenv("INCIDENTS_TABLE_NAME", "incidents")

    if not account_name:
        raise RuntimeError("APP_STORAGE_ACCOUNT_NAME is not configured.")

    endpoint = f"https://{account_name}.table.core.windows.net"
    credential = DefaultAzureCredential()
    service = TableServiceClient(endpoint=endpoint, credential=credential)
    return service.get_table_client(table_name=table_name)


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


def validate_incident_payload(payload: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    if not str(payload.get("title", "")).strip():
        errors.append("title is required")
    if not str(payload.get("service", "")).strip():
        errors.append("service is required")

    severity = str(payload.get("severity", "medium")).lower()
    if severity not in {"low", "medium", "high", "critical"}:
        errors.append("severity must be low, medium, high or critical")

    return errors


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
        table = get_table_client()

        if req.method == "GET":
            rows = [normalize_entity(dict(entity)) for entity in table.list_entities()]
            rows.sort(key=lambda item: item.get("createdAt") or "", reverse=True)
            return json_response({"items": rows, "count": len(rows)})

        try:
            payload = req.get_json()
        except ValueError:
            return json_response({"error": "Request body must be valid JSON."}, 400)

        errors = validate_incident_payload(payload)
        if errors:
            return json_response({"error": "Validation failed.", "details": errors}, 400)

        now = utc_now_iso()
        incident_id = f"INC-{datetime.now(timezone.utc).strftime('%Y%m%d')}-{uuid.uuid4().hex[:6].upper()}"

        entity = {
            "PartitionKey": "INCIDENT",
            "RowKey": incident_id,
            "Title": str(payload["title"]).strip(),
            "Service": str(payload["service"]).strip(),
            "Severity": str(payload.get("severity", "medium")).lower(),
            "Status": "open",
            "Description": str(payload.get("description", "")).strip(),
            "CreatedAt": now,
            "UpdatedAt": now,
        }

        table.create_entity(entity=entity)
        logging.info("Created incident %s", incident_id)
        return json_response(normalize_entity(entity), 201)

    except Exception as exc:  # Azure telemetry receives the full stack trace.
        logging.exception("Incident endpoint failed")
        return json_response({"error": "Internal server error.", "detail": str(exc)}, 500)


@app.route(route="incidents/{incident_id}", methods=["GET", "PUT", "OPTIONS"])
def incident_by_id(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return json_response({}, 204)

    incident_id = req.route_params.get("incident_id")
    if not incident_id:
        return json_response({"error": "incident_id is required"}, 400)

    try:
        table = get_table_client()

        if req.method == "GET":
            entity = table.get_entity(partition_key="INCIDENT", row_key=incident_id)
            return json_response(normalize_entity(dict(entity)))

        try:
            payload = req.get_json()
        except ValueError:
            return json_response({"error": "Request body must be valid JSON."}, 400)

        allowed_statuses = {"open", "investigating", "resolved", "closed"}
        status = str(payload.get("status", "")).lower()
        if status not in allowed_statuses:
            return json_response(
                {"error": "status must be open, investigating, resolved or closed"},
                400,
            )

        entity = {
            "PartitionKey": "INCIDENT",
            "RowKey": incident_id,
            "Status": status,
            "UpdatedAt": utc_now_iso(),
        }
        table.update_entity(entity=entity, mode=UpdateMode.MERGE)
        updated = table.get_entity(partition_key="INCIDENT", row_key=incident_id)
        logging.info("Updated incident %s to %s", incident_id, status)
        return json_response(normalize_entity(dict(updated)))

    except ResourceNotFoundError:
        return json_response({"error": "Incident not found."}, 404)
    except Exception as exc:
        logging.exception("Incident-by-id endpoint failed")
        return json_response({"error": "Internal server error.", "detail": str(exc)}, 500)
