# Keyless Enterprise AI Gateway with APIM and Microsoft Foundry

[Launch the MOAW workshop](https://aka.ms/ws?src=gh:yelghali/foundry-ai-gateway/main/docs/) | [Read the workshop source](docs/workshop.md)

This repository implements a customer-owned Azure API Management gateway for four AI surfaces:

- An OpenAI-compatible model API backed by two Microsoft Foundry regions.
- The Microsoft Learn MCP server exposed through APIM.
- A versioned Foundry Toolbox exposed as MCP through APIM.
- A Foundry-hosted enterprise agent exposed as A2A through APIM.

Every surface is tested by two consumers: a local Microsoft Agent Framework application and a prompt agent hosted by Foundry Agent Service. An optional sixth scenario repeats model, MCP, and A2A access through a customer-operated LiteLLM gateway.

![Two consumers use Microsoft Entra identities to reach model, MCP, Toolbox, and A2A APIs on customer-owned APIM.](docs/assets/keyless-overview.svg)

## Authentication model

The core APIM path is keyless:

1. The local application uses `DefaultAzureCredential`.
2. Foundry Agent Service uses project-scoped connections with `ProjectManagedIdentity`.
3. APIM validates tenant, audience, and an explicit caller `oid` allowlist.
4. APIM uses its system-assigned managed identity for Foundry backends.
5. APIM removes the caller token before forwarding to the public Microsoft Learn MCP server.

All four APIs have `subscriptionRequired: false`. The deployment does not create or distribute APIM subscription keys, model keys, or connection secrets.

Scenarios 1-5 use a Foundry **bring-your-own-model `ApiManagement` connection** to customer-owned APIM. Scenario 6 separately registers LiteLLM as a generic **`ModelGateway`**. Neither path uses Foundry's integrated AI Gateway attachment.

The optional LiteLLM edge requires a bearer credential because the current `ModelGateway` connection contract does not support project managed identity. LiteLLM uses managed identity downstream for its private Foundry model endpoints. See the workshop's Scenario 6 comparison before choosing between these connection types.

## Network scope

Keyless authentication and network isolation are separate controls. This workshop intentionally enables public network access on its Foundry resources and uses APIM's public gateway so a learner can run the local consumer without private network access.

A Toolbox is a logical container and does not deploy networking resources of its own. The hosting Foundry project's network configuration governs access to the Toolbox, while each downstream tool type has its own traffic path. In this lab:

- Toolbox ingress goes from the consumer through the public APIM gateway to the public Foundry project endpoint.
- The Toolbox's MCP tool reaches the public APIM gateway with the publisher project managed identity, and APIM forwards to the public Microsoft Learn MCP server without that credential.

For a network-isolated deployment, secure the hosting project with a private endpoint and VNet injection. Microsoft documents MCP traffic as supported through the project's delegated subnet. To keep the Foundry-to-APIM hop private, make APIM privately reachable with matching DNS from that subnet. The Microsoft Learn MCP upstream remains public, so a requirement that every hop stay private also requires a privately reachable MCP server instead. This is a separate production topology, not a Toolbox-level switch; see [Network isolation for a toolbox in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/toolbox-network-isolation).

## Implemented scenarios

| Scenario | Local MAF | Foundry Agent Service | Primary implementation |
|---|---:|---:|---|
| 1. Model through APIM | Yes | Yes | `scenario1_maf_model_apim.py`, `scenario1_foundry_model_apim.py` |
| 2. Raw MCP through APIM | Yes | Yes | `scenario2_maf_mcp_apim.py`, `scenario2_foundry_mcp_apim.py` |
| 3. Foundry Toolbox through APIM | Yes | Yes | `scenario3_maf_toolbox_apim.py`, `scenario3_foundry_toolbox_apim.py` |
| 4. Foundry enterprise agent through APIM A2A | Yes | Yes | `scenario4_maf_enterprise_agent_apim.py`, `scenario4_foundry_agent_apim.py` |
| 5. Model + Toolbox + A2A combined workflow | All three through APIM | Toolbox + A2A through APIM; native model driver | `scenario5_maf_combined_workflow.py`, `scenario5_foundry_combined_workflow.py` |
| APIM observability | Portal or PowerShell | Gateway request metadata and platform metrics | `show-apim-observability.ps1` |
| 6. LiteLLM model + MCP + A2A (optional) | Yes | Yes | `scenario6_maf_litellm.py`, `scenario6_foundry_litellm.py` |
| Security boundary | 8 denied requests | Anonymous and wrong audience | `scenario_security_boundaries.py` |

All scenario files are under `src/test/`.

## Workshop quick start

The workshop uses a predeployed environment. Learners need Azure CLI, Python 3.11+, PowerShell, access to the workshop subscription, and an identity already included in the APIM caller allowlist. They do not run infrastructure deployments.

```powershell
az login
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table

if (-not (Test-Path .\src\test\.venv)) {
	python -m venv .\src\test\.venv
}
& .\src\test\.venv\Scripts\python.exe -m pip install -r .\src\test\requirements.txt

$config = Get-Content .\infra\scenario-outputs.json -Raw | ConvertFrom-Json
$config.apimGatewayUrl
$config.modelApimMiUrl
$config.rawMcpApimUrl
$config.toolboxApimUrl
$config.enterpriseAgentApimUrl

.\src\test\run-two-consumer-scenarios.ps1
.\src\test\show-apim-observability.ps1 -LookbackMinutes 120
```

If the resource group is not visible, select the facilitator-provided subscription with `az account set --subscription "<subscription-id>"` and rerun the checks.

If Azure CLI is not on `PATH`, set `AZ_CMD` before running the scripts:

```powershell
$env:AZ_CMD = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
```

A successful full run ends with:

```text
All two-consumer scenarios passed.
```

Run the already configured optional BYOM comparison separately:

```powershell
$env:LITELLM_API_KEY = "<facilitator-issued-scoped-key>"
try {
	.\src\test\run-litellm-scenario.ps1
} finally {
	Remove-Item Env:LITELLM_API_KEY -ErrorAction SilentlyContinue
}
```

The facilitator provides a scoped LiteLLM virtual key through an approved secret channel. The key is limited to the configured model, the `mslearn` MCP server, and the registered `dummy-specialist` A2A agent. Maintainers with access to the local Terraform state can instead pass `-UseTerraformAdminKey`; learners do not need Terraform or the administrator key.

## Facilitator rebuild

Only the facilitator or repository maintainer provisions the shared environment. The supported order is:

```powershell
.\infra\deploy.ps1
.\infra\deploy-foundry-consumers.ps1
.\infra\deploy-two-consumer-apim.ps1
.\infra\deploy-enterprise-foundry-agent-apim.ps1
```

These entry points combine Azure control-plane IaC with repeatable Foundry data-plane setup. They merge non-secret endpoints and resource IDs into `infra/scenario-outputs.json` for the learner scripts. The optional LiteLLM path has its own Terraform stack and `infra/deploy-litellm-scenario.ps1` connection deployment.

The optional deployment generates a budgeted virtual key scoped to the configured model, the `mslearn` MCP server, and the registered `dummy-specialist` A2A agent. It reapplies the Foundry connections, creates a new A2A shim revision that loads the credential, and stores the facilitator copy with Windows DPAPI outside the repository. Run `infra/copy-litellm-workshop-key.ps1` to place it on the clipboard for approved distribution; the value is not printed.

## Active infrastructure

| File | Responsibility |
|---|---|
| `infra/main.bicep` | APIM Standard v2, two enterprise Foundry regions, model deployments, backend pool, keyless model API, Log Analytics workspace, and service diagnostic setting. |
| `infra/policy-mi.xml` | Entra validation, backend selection, APIM managed identity, and retry. |
| `infra/foundry-consumers.bicep` | Toolbox publisher project, Foundry app project, native driver, and `ApiManagement` model connection. |
| `infra/two-consumer-apim.bicep` | Explicit caller allowlist, raw MCP API, Toolbox API, and project-managed-identity tool connections. |
| `infra/enterprise-foundry-agent-apim.bicep` | Foundry A2A backend, APIM facade, card rewriting, least-privilege role, and `RemoteA2A` connection. |
| `infra/litellm-foundry-connections.bicep` | Optional `ModelGateway`, MCP, and authenticated A2A connections over the standalone LiteLLM stack. |
| `infra/scenario-outputs.json` | Generated secret-free endpoints and resource IDs used by the tests. |
| `src/test/show-apim-observability.ps1` | Read-only KQL query for model, raw MCP, Toolbox, and A2A gateway records. |

The PowerShell files with matching `deploy-*.ps1` names are the supported deployment entry points.

## Live verification

The current implementation was deployed and rerun against Azure. The full suite passed:

- Both consumers reached the APIM model pool.
- Both consumers invoked raw MCP through APIM.
- Both consumers invoked the Foundry Toolbox through the public APIM gateway; the Toolbox's MCP egress also crossed that gateway.
- Both consumers discovered and invoked the Foundry-hosted A2A agent through APIM.
- Both combined workflows returned research and governance answers.
- Anonymous and wrong-audience requests returned HTTP 401 on all four surfaces.
- The live APIM instance exposes only the four supported APIs, all with `subscriptionRequired: false`.
- APIM exports gateway request metadata and metrics to resource-specific Log Analytics tables. Content-bearing generative AI diagnostics are disabled by default; records ingested before that setting was applied remain subject to workspace retention.
- The optional LiteLLM suite passed model, MCP, and A2A calls from both consumers; missing and invalid bearer credentials returned HTTP 401 on every LiteLLM edge.

## Known preview limitation

Foundry Agent Service currently returns HTTP 500 when the Toolbox in this lab is paired with the `ApiManagement` connected model. The Foundry Toolbox scenarios therefore use the app project's native `gpt-4o-mini` driver while Toolbox ingress and egress still cross the public APIM gateway. The connected APIM model works with raw MCP in Scenario 2.

## Other repository areas

`litellm-gateway/litellm-azure-private-endpoints/` supplies the optional Scenario 6 gateway. `rag-demo/` and older scenario/deployment files remain separate experiments and are not part of the supported paths above.

## Facilitator cleanup

```powershell
.\infra\cleanup.ps1
```

The command deletes the lab resource group asynchronously. Learners should not run it during a shared workshop.
