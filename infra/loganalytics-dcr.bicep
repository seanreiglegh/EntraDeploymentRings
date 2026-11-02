// =============================================================================
//  loganalytics-dcr.bicep
//  Revision: 1.0
//
//  Creates everything Invoke-EntraDeploymentRings.ps1 needs to log to Log
//  Analytics through the Logs Ingestion API:
//    - Custom table EntraDeploymentRings_CL in an existing workspace
//    - Data Collection Rule (kind Direct, so no separate DCE is required)
//    - "Monitoring Metrics Publisher" on the DCR for the identity that runs
//      the script (app registration service principal or managed identity)
//
//  Deploy into the resource group that holds the workspace:
//    az deployment group create -g <rg> -f infra/loganalytics-dcr.bicep \
//      -p workspaceName=<workspace> ingestionPrincipalId=<objectId>
//
//  Outputs map directly to the script parameters LogIngestionEndpoint and
//  LogDcrImmutableId.
//
//  REVISION HISTORY (most recent first)
//  1.0   2026-11-01  First public release.
// =============================================================================

@description('Name of an existing Log Analytics workspace in this resource group.')
param workspaceName string

@description('Region for the Data Collection Rule. Must match the workspace region.')
param location string = resourceGroup().location

@description('Name of the Data Collection Rule.')
param dcrName string = 'dcr-entra-deployment-rings'

@description('Object ID of the service principal or managed identity that runs the script. Leave empty to skip the role assignment.')
param ingestionPrincipalId string = ''

@description('Principal type of ingestionPrincipalId.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

@description('Interactive retention for the custom table, in days.')
@minValue(4)
@maxValue(730)
param retentionInDays int = 365

var tableName = 'EntraDeploymentRings_CL'
var streamName = 'Custom-${tableName}'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

var columns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RunId', type: 'string' }
  { name: 'RecordType', type: 'string' }
  { name: 'RingSet', type: 'string' }
  { name: 'Action', type: 'string' }
  { name: 'UserId', type: 'string' }
  { name: 'UserPrincipalName', type: 'string' }
  { name: 'GroupName', type: 'string' }
  { name: 'GroupId', type: 'string' }
  { name: 'RingKey', type: 'string' }
  { name: 'Reason', type: 'string' }
  { name: 'Result', type: 'string' }
  { name: 'ErrorMessage', type: 'string' }
  { name: 'IsWhatIf', type: 'boolean' }
  { name: 'ScriptRevision', type: 'string' }
  { name: 'Details', type: 'dynamic' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: tableName
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    schema: {
      name: tableName
      columns: columns
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Direct'
  properties: {
    description: 'Ingests run records from Invoke-EntraDeploymentRings.ps1'
    streamDeclarations: {
      '${streamName}': {
        columns: columns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          streamName
        ]
        destinations: [
          'workspace'
        ]
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [
    table
  ]
}

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(ingestionPrincipalId)) {
  name: guid(dcr.id, ingestionPrincipalId, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: ingestionPrincipalId
    principalType: principalType
  }
}

@description('Value for the script parameter LogIngestionEndpoint.')
output logIngestionEndpoint string = dcr.properties.endpoints.logsIngestion

@description('Value for the script parameter LogDcrImmutableId.')
output dcrImmutableId string = dcr.properties.immutableId

@description('Value for the script parameter LogStreamName.')
output streamName string = streamName
