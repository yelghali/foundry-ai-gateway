resource "azurerm_monitor_action_group" "ActionGroup" {
  provider            = azurerm.miroki-dev
  enabled             = true
  location            = "global"
  name                = "Application Insights Smart Detection"
  resource_group_name = "rg-miroki-monitoring-dev-frc-01"
  short_name          = "SmartDetect"
  tags                = {
    Environment = "DEV"
    Application = "Miroki"
    Service     = "Monitor"  
  }
  arm_role_receiver {
    name                    = "Monitoring Contributor"
    role_id                 = "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
    use_common_alert_schema = true
  }
  arm_role_receiver {
    name                    = "Monitoring Reader"
    role_id                 = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
    use_common_alert_schema = true
  }
  depends_on = [azurerm_application_insights.ApplicationInsights,azurerm_log_analytics_workspace.LogAnalyticsWorkspace] 
}

resource "azurerm_monitor_smart_detector_alert_rule" "AlertRule" {
  provider            = azurerm.miroki-dev
  description         = "Failure Anomalies notifies you of an unusual rise in the rate of failed HTTP requests or dependency calls."
  detector_type       = "FailureAnomaliesDetector"
  enabled             = true
  frequency           = "PT1M"
  name                = "Failure Anomalies - appi-litellm-enc6ggxvai3se"
  resource_group_name = "rg-miroki-monitoring-dev-frc-01"
  scope_resource_ids  = ["/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourcegroups/rg-miroki-monitoring-dev-frc-01/providers/microsoft.insights/components/appi-icm-miroki-dev-frc-01"]
  severity            = "Sev3"
  tags                = {
     Environment = "DEV"
    Application = "Miroki"
    Service     = "Monitor"   
  }
//  throttling_duration = ""
  action_group {
    email_subject   = ""
    ids             = ["/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-monitoring-dev-frc-01/providers/Microsoft.Insights/actionGroups/application insights smart detection"]
    webhook_payload = ""
  }
  depends_on = [azurerm_monitor_action_group.ActionGroup] 
}
