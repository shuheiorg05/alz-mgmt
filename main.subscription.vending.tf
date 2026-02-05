# ========================================
# Terraformのサブスクリプションリソースの実装
# ========================================

locals {
  # subscriptions/ディレクトリからYAMLファイルを読み込む
  subscription_files = fileset("${path.module}/subscriptions", "*.yaml")

  # YAMLをパースして設定を作成（README.mdは説明用のファイルとして除外）
  subscriptions = {
    for file in local.subscription_files :
    trimsuffix(file, ".yaml") => yamldecode(file("${path.module}/subscriptions/${file}"))
    if file != "README.md"
  }
}

# 手順3: 管理グループIDの取得
data "azurerm_management_group" "subscription_target" {
  for_each = local.subscriptions

  name = each.value.management_group_id

  depends_on = [
    module.management_groups
  ]
}

# データソースでBilling Scopeを取得
data "azurerm_billing_mca_account_scope" "this" {
  count = var.billing_account_name != null && var.billing_profile_name != null && var.invoice_section_name != null ? 1 : 0

  billing_account_name = var.billing_account_name
  billing_profile_name = var.billing_profile_name
  invoice_section_name = var.invoice_section_name
}

# 手順4: サブスクリプションの作成
resource "azurerm_subscription" "this" {
  for_each = local.subscriptions

  subscription_name = each.value.display_name
  alias             = each.key
  billing_scope_id  = data.azurerm_billing_mca_account_scope.this[0].id
  workload          = lookup(each.value, "workload_type", "Production")

  tags = lookup(each.value, "tags", {})
}

# 手順5: Subscription Alias に対するロール割り当て
resource "azurerm_role_assignment" "alias_plan" {
  for_each = local.subscriptions

  scope                = "/providers/Microsoft.Subscription/aliases/${each.key}"
  role_definition_name = "Owner"
  principal_id         = var.plan_service_principal_object_id

  depends_on = [azurerm_subscription.this]
}

# 手順6: 管理グループへの関連付け
resource "azurerm_management_group_subscription_association" "this" {
  for_each = local.subscriptions

  management_group_id = data.azurerm_management_group.subscription_target[each.key].id
  subscription_id     = "/subscriptions/${azurerm_subscription.this[each.key].subscription_id}"

  depends_on = [azurerm_subscription.this]
}

# 手順7: リソースグループの作成
locals {
  # 全サブスクリプションのリソースグループをフラット化
  subscription_resource_groups = merge([
    for sub_key, sub in local.subscriptions : {
      for rg_key, rg in lookup(sub, "resource_groups", {}) :
      "${sub_key}-${rg_key}" => merge(rg, {
        subscription_id = azurerm_subscription.this[sub_key].subscription_id
        location        = lookup(rg, "location", lookup(sub, "location", "japaneast"))
        tags            = lookup(sub, "tags", {})
      })
    }
  ]...)
}

resource "azapi_resource" "resource_group" {
  for_each = local.subscription_resource_groups

  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = each.value.name
  location  = each.value.location
  parent_id = "/subscriptions/${each.value.subscription_id}"

  body = {
    properties = {}
  }

  tags = each.value.tags

  lifecycle {
    ignore_changes = [tags]
  }

  depends_on = [
    azurerm_subscription.this,
    azurerm_role_assignment.alias_plan
  ]
}

# 手順8: リソースプロバイダーの登録
# 新しいサブスクリプションではMicrosoft.Networkが登録されていないため、
# VNet作成前に登録が必要
resource "azapi_resource_action" "register_network_provider" {
  for_each = local.subscriptions

  type        = "Microsoft.Resources/providers@2022-09-01"
  resource_id = "/subscriptions/${azurerm_subscription.this[each.key].subscription_id}/providers/Microsoft.Network"
  action      = "register"
  method      = "POST"

  depends_on = [
    azurerm_subscription.this,
    azurerm_role_assignment.alias_plan
  ]
}

# 手順9: VNetの作成
locals {
  # VNetが定義されているサブスクリプションを抽出
  vnets = {
    for sub_key, sub in local.subscriptions :
    sub_key => merge(sub.virtual_network, {
      subscription_id = azurerm_subscription.this[sub_key].subscription_id
      location        = lookup(sub.virtual_network, "location", lookup(sub, "location", "japaneast"))
      tags            = lookup(sub, "tags", {})
    })
    if lookup(sub, "virtual_network", null) != null
  }
}

resource "azapi_resource" "virtual_network" {
  for_each = local.vnets

  type      = "Microsoft.Network/virtualNetworks@2024-01-01"
  name      = each.value.name
  location  = each.value.location
  parent_id = "/subscriptions/${each.value.subscription_id}/resourceGroups/${each.value.resource_group_name}"

  body = {
    properties = {
      addressSpace = {
        addressPrefixes = each.value.address_space
      }
    }
  }

  tags = each.value.tags

  depends_on = [
    azapi_resource.resource_group,
    azurerm_subscription.this,
    azapi_resource_action.register_network_provider
  ]
}

# 手順9: サブネットの作成
locals {
  # 全VNetのサブネットをフラット化
  subnets = merge([
    for sub_key, vnet in local.vnets : {
      for subnet in lookup(vnet, "subnets", []) :
      "${sub_key}-${subnet.name}" => {
        name                = subnet.name
        vnet_name           = vnet.name
        resource_group_name = vnet.resource_group_name
        address_prefix      = subnet.address_prefix
        subscription_id     = vnet.subscription_id
      }
    }
  ]...)
}

resource "azapi_resource" "subnet" {
  for_each = local.subnets

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = "/subscriptions/${each.value.subscription_id}/resourceGroups/${each.value.resource_group_name}/providers/Microsoft.Network/virtualNetworks/${each.value.vnet_name}"

  body = {
    properties = {
      addressPrefix = each.value.address_prefix
    }
  }

  depends_on = [azapi_resource.virtual_network]
}

# 手順11: Hub VNetへのピアリング
locals {
  # Hub接続が必要なVNetを抽出
  # Hub VNet情報は既存のhub_and_spoke_vnetモジュールから自動取得
  hub_vnet_id = try(
    values(module.hub_and_spoke_vnet[0].virtual_network_resource_ids)[0],
    var.hub_virtual_network_id
  )
  hub_vnet_name = try(
    values(module.hub_and_spoke_vnet[0].virtual_network_resource_names)[0],
    var.hub_virtual_network_name
  )
  hub_vnet_resource_group = try(
    split("/", local.hub_vnet_id)[4],
    var.hub_virtual_network_resource_group_name
  )

  vnet_peerings = {
    for sub_key, sub in local.subscriptions :
    sub_key => merge(sub.virtual_network, {
      subscription_key = sub_key
    })
    if lookup(sub, "virtual_network", null) != null &&
    lookup(sub.virtual_network, "hub_peering_enabled", false)
  }
}

# Spoke → Hub のピアリング
resource "azapi_resource" "spoke_to_hub_peering" {
  for_each = local.vnet_peerings

  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
  name      = "${each.value.name}-to-hub"
  parent_id = "/subscriptions/${azurerm_subscription.this[each.value.subscription_key].subscription_id}/resourceGroups/${each.value.resource_group_name}/providers/Microsoft.Network/virtualNetworks/${each.value.name}"

  body = {
    properties = {
      remoteVirtualNetwork = {
        id = local.hub_vnet_id
      }
      allowVirtualNetworkAccess = true
      allowForwardedTraffic     = true
      allowGatewayTransit       = false
      useRemoteGateways         = lookup(each.value, "use_hub_gateway", false)
    }
  }

  depends_on = [azapi_resource.virtual_network]
}

# Hub → Spoke のピアリング（connectivityサブスクリプションのプロバイダーを使用）
resource "azapi_resource" "hub_to_spoke_peering" {
  provider = azapi.connectivity
  for_each = local.vnet_peerings

  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
  name      = "hub-to-${each.value.name}"
  parent_id = local.hub_vnet_id

  body = {
    properties = {
      remoteVirtualNetwork = {
        id = "/subscriptions/${azurerm_subscription.this[each.value.subscription_key].subscription_id}/resourceGroups/${each.value.resource_group_name}/providers/Microsoft.Network/virtualNetworks/${each.value.name}"
      }
      allowVirtualNetworkAccess = true
      allowForwardedTraffic     = true
      allowGatewayTransit       = lookup(each.value, "use_hub_gateway", false)
      useRemoteGateways         = false
    }
  }

  depends_on = [azapi_resource.virtual_network]
}