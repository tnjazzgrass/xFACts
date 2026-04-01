# dbo.ApiRegistry & dbo.ApiSchemaRegistry — Table Design

**Purpose:** Catalog the complete DM REST API surface area (and potentially other products' APIs in the future) for use by xFACts modules that need to discover, reference, or automate API interactions.

**Component:** Engine.SharedInfrastructure  
**Schema:** dbo  
**Source:** OpenAPI 3.0 YAML specification files

---

## Overview

Two tables work together:

- **`dbo.ApiRegistry`** — One row per endpoint (path + HTTP method). Answers: "What can the API do?"
- **`dbo.ApiSchemaRegistry`** — One row per property within each schema/model object. Answers: "What data flows through each endpoint?"

They link via schema name: an endpoint's `request_schema` or `response_schema` points to rows in the schema registry.

**Current data volume (DM R11.1.0.1):**
- ApiRegistry: 738 endpoints
- ApiSchemaRegistry: ~4,244 properties across 450 schemas

---

## Table 1: dbo.ApiRegistry

One row per API endpoint (path + HTTP method combination).

### Primary Key

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| endpoint_id | INT IDENTITY(1,1) | No | — | Unique row identifier |

### Endpoint Identity

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| spec_version | VARCHAR(30) | No | — | OpenAPI spec version (e.g., '11.1.0.1.6'). No default constraint — every insert must explicitly specify. |
| product_name | VARCHAR(50) | No | — | Source product (e.g., 'Debt Manager'). Enables future multi-product cataloging. |
| resource_tag | VARCHAR(50) | No | — | OpenAPI tag / resource group (e.g., 'accounts', 'consumers', 'legal'). One tag per endpoint — no multi-tag endpoints exist in this spec. |
| endpoint_path | VARCHAR(200) | No | — | URL path template (e.g., '/accounts/{account_agency_id}/consumers'). |
| http_method | VARCHAR(10) | No | — | HTTP verb: GET, POST, PUT, DELETE. |
| operation_id | VARCHAR(100) | No | — | OpenAPI operationId (e.g., 'retrieveConsumerAccountCaseDetails'). Unique per spec version. |

### Descriptive

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| summary | VARCHAR(200) | Yes | NULL | Short one-line summary from spec. |
| description | VARCHAR(MAX) | Yes | NULL | Full description from spec (may contain HTML markup). |
| operation_type | VARCHAR(20) | Yes | NULL | Classified CRUD type: CREATE, RETRIEVE, UPDATE, DELETE, SEARCH, ACTION. Derived from operationId patterns during import. |

### Request / Response Schema

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| request_content_type | VARCHAR(60) | Yes | NULL | Request MIME type (e.g., 'application/vnd.fico.dm.v1+json'). NULL for GET/DELETE with no body. |
| request_schema | VARCHAR(80) | Yes | NULL | Schema name for request body (e.g., 'ConsumerAccountCaseRequestRM'). NULL when no body. |
| response_content_type | VARCHAR(60) | Yes | NULL | Response MIME type for 200/201 status. NULL for 204 No Content responses. |
| response_schema | VARCHAR(80) | Yes | NULL | Schema name for successful response (e.g., 'ConsumerAccountCaseDetailsRM'). |
| response_is_array | BIT | No | 0 | Whether the 200 response is an array of the schema type. |

### Parameters

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| path_params | VARCHAR(500) | Yes | NULL | Comma-separated list of path parameter names (e.g., 'account_agency_id, consumer_agency_id'). |
| query_params | VARCHAR(500) | Yes | NULL | Comma-separated list of query parameter names (e.g., 'firstresult, maxresults, date'). |
| path_param_count | SMALLINT | No | 0 | Number of path parameters. |
| query_param_count | SMALLINT | No | 0 | Number of query parameters. |

### Flags

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| is_deprecated | BIT | No | 0 | Whether the endpoint is marked deprecated in the spec. |
| api_version | SMALLINT | Yes | NULL | FICO API version number extracted from content type (1, 2, 3, or 4). |

### Constraints

| Object | Type | Columns | Description |
|--------|------|---------|-------------|
| PK_ApiRegistry | Primary Key | endpoint_id | Clustered unique row identifier |
| UQ_ApiRegistry_Endpoint | Unique | spec_version, endpoint_path, http_method | One row per endpoint per spec version |
| UQ_ApiRegistry_OperationId | Unique | spec_version, operation_id | Operation IDs are unique within a spec |
| DF_ApiRegistry_response_is_array | Default | response_is_array | 0 |
| DF_ApiRegistry_path_param_count | Default | path_param_count | 0 |
| DF_ApiRegistry_query_param_count | Default | query_param_count | 0 |
| DF_ApiRegistry_is_deprecated | Default | is_deprecated | 0 |

### Indexes

| Index | Columns | Includes | Purpose |
|-------|---------|----------|---------|
| IX_ApiRegistry_Tag | resource_tag, spec_version | operation_id, http_method, summary | Browse endpoints by resource group |
| IX_ApiRegistry_Schema | request_schema, response_schema | endpoint_path, http_method, operation_id | Find endpoints that use a specific schema |

---

## Table 2: dbo.ApiSchemaRegistry

One row per property within each schema/model object.

### Primary Key

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| schema_property_id | INT IDENTITY(1,1) | No | — | Unique row identifier |

### Schema Identity

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| spec_version | VARCHAR(30) | No | — | Same spec version as ApiRegistry. No default constraint. |
| product_name | VARCHAR(50) | No | — | Source product (e.g., 'Debt Manager'). |
| schema_name | VARCHAR(80) | No | — | Model object name (e.g., 'ConsumerAccountCaseRequestRM', 'AREventRM'). |

### Schema-Level Metadata

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| schema_description | VARCHAR(500) | Yes | NULL | Schema-level description (repeated on each property row for that schema). |
| schema_property_count | SMALLINT | No | — | Total properties in this schema (repeated per row for query convenience). |

### Property Detail

| Column | Type | Null | Default | Description |
|--------|------|------|---------|-------------|
| property_name | VARCHAR(80) | No | — | JSON property name (e.g., 'consumerAgencyIdentifier', 'caseName'). |
| property_type | VARCHAR(20) | Yes | NULL | Data type: string, integer, boolean, number, array, object. NULL when type is a $ref. |
| property_format | VARCHAR(30) | Yes | NULL | OpenAPI format qualifier (e.g., 'date-time', 'int64'). NULL when not specified. |
| property_description | VARCHAR(MAX) | Yes | NULL | Full description from spec. Often includes DM column names in parentheses. |
| ref_schema | VARCHAR(80) | Yes | NULL | Referenced schema name if this property is a $ref or array of $ref (e.g., 'ReferenceRM'). NULL for primitive types. |
| is_array | BIT | No | 0 | Whether this property is an array type. |
| is_required | BIT | No | 0 | Whether this property is marked required in the spec (from the schema's 'required' list). |
| is_read_only | BIT | No | 0 | Whether the description indicates READ-ONLY. |
| default_value | VARCHAR(100) | Yes | NULL | Default value if specified in the spec. |
| sort_order | SMALLINT | No | — | Ordinal position of this property within its parent schema (1-based). |

### Constraints

| Object | Type | Columns | Description |
|--------|------|---------|-------------|
| PK_ApiSchemaRegistry | Primary Key | schema_property_id | Clustered unique row identifier |
| UQ_ApiSchemaRegistry_Property | Unique | spec_version, schema_name, property_name | One row per property per schema per version |
| DF_ApiSchemaRegistry_is_array | Default | is_array | 0 |
| DF_ApiSchemaRegistry_is_required | Default | is_required | 0 |
| DF_ApiSchemaRegistry_is_read_only | Default | is_read_only | 0 |

### Indexes

| Index | Columns | Includes | Purpose |
|-------|---------|----------|---------|
| IX_ApiSchemaRegistry_Schema | schema_name, spec_version | property_name, property_type, ref_schema | Look up all properties for a given schema |
| IX_ApiSchemaRegistry_RefSchema | ref_schema | schema_name, property_name | Find which schemas reference a given schema (relationship traversal) |

---

## How They Work Together

**Example: "I want to create a case via the API — what do I need?"**

```sql
-- Step 1: Find the endpoint
SELECT endpoint_path, http_method, operation_id, request_schema, response_schema
FROM dbo.ApiRegistry
WHERE resource_tag = 'accountcases'
  AND operation_type = 'CREATE'
  AND spec_version = '11.1.0.1.6';

-- Returns: POST /accountcases, request_schema = 'ConsumerAccountCaseRequestRM'

-- Step 2: See what fields the request body needs
SELECT property_name, property_type, ref_schema, is_required, property_description
FROM dbo.ApiSchemaRegistry
WHERE schema_name = 'ConsumerAccountCaseRequestRM'
  AND spec_version = '11.1.0.1.6'
ORDER BY sort_order;

-- Returns: consumerAgencyIdentifier (integer), caseName (string), etc.
```

**Example: "What endpoints return consumer data?"**

```sql
SELECT r.endpoint_path, r.http_method, r.operation_id, r.response_schema
FROM dbo.ApiRegistry r
WHERE r.response_schema IN (
    SELECT DISTINCT schema_name 
    FROM dbo.ApiSchemaRegistry 
    WHERE property_name LIKE '%consumer%'
      AND spec_version = '11.1.0.1.6'
)
AND r.spec_version = '11.1.0.1.6';
```

**Example: "What DM database columns are exposed through the API?"**

```sql
-- Many property descriptions contain DM column names in parentheses
SELECT schema_name, property_name, property_description
FROM dbo.ApiSchemaRegistry
WHERE property_description LIKE '%(%_%)%'
  AND spec_version = '11.1.0.1.6'
ORDER BY schema_name, sort_order;
```

---

## Design Decisions

1. **`product_name` column** — Enables future multi-product API cataloging without table restructuring. For now, all rows will be 'Debt Manager'.

2. **Denormalized schema description/count** — `schema_description` and `schema_property_count` are repeated on every property row. This avoids a third table (a schema header table) while keeping queries simple. The trade-off is ~450 repeated descriptions across ~4,244 rows — minimal storage cost.

3. **`operation_type` derived during import** — Classified from operationId patterns (create*/add*/save* → CREATE, retrieve*/get*/list* → RETRIEVE, etc.). Not stored in the spec itself. "ACTION" catches non-CRUD operations like status updates and batch processing triggers.

4. **`api_version` as SMALLINT** — FICO uses versioned content types (v1, v2, v3, v4). Extracting just the number enables easy filtering. The full content type string is preserved in `request_content_type` / `response_content_type`.

5. **Parameters as comma-separated lists** — Individual parameter details (type, required, description) are available in the shared parameters section of the spec and don't vary per endpoint. Storing the names as lists keeps the endpoint table lean. If parameter-level detail becomes important later, a third table could be added.

6. **`is_read_only` derived from description** — Many schema properties include "READ-ONLY" in their description text. Extracting this flag makes it queryable without text searching.

7. **No foreign key between tables** — The link is by schema name (string), not by ID. This keeps the import process simple (no insert-order dependencies) and supports the case where an endpoint references a schema not yet imported, or a schema exists that no current endpoint references.

---

## Row Counts (DM R11.1.0.1.6)

| Table | Expected Rows |
|-------|---------------|
| dbo.ApiRegistry | 738 |
| dbo.ApiSchemaRegistry | ~4,244 |
