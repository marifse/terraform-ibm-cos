locals {
  # tflint-ignore: terraform_unused_declarations
  bucket_validations = [
    for bucket in var.bucket_configs : {
      validate_at_set               = can(bucket.activity_tracking.activity_tracker_crn) ? bucket.activity_tracking.activity_tracker_crn == null ? tobool("When activity_tracking is set, activity_tracker_crn must be provided.") : null : null,
      validate_sysdig_set           = can(bucket.metrics_monitoring.metrics_monitoring_crn) ? bucket.metrics_monitoring.metrics_monitoring_crn == null ? tobool("When metrics_monitoring is set, metrics_monitoring_crn must be provided.") : null : null,
      validate_hpcs_instance_guid   = bucket.skip_iam_authorization_policy == false && bucket.kms_guid == null ? tobool("'kms_guid' must be provided if 'skip_iam_authorization_policy' is set to false") : null,
      validate_hpcs_key_crn         = bucket.kms_key_crn == null ? tobool("When kms_encryption_enabled is set, kms_key_crn must be provided.") : null,
      validate_single_site_location = bucket.single_site_location != null ? tobool("KMS encryption can not be added to single site location, therefore it is not supported in fscloud module.") : null,
    }
  ]
}



module "cos_instance" {
  source                        = "../../"
  resource_group_id             = var.resource_group_id
  create_cos_instance           = var.create_cos_instance
  existing_cos_instance_id      = var.existing_cos_instance_id
  create_cos_bucket             = false
  skip_iam_authorization_policy = true
  cos_instance_name             = var.cos_instance_name
  create_resource_key           = var.create_resource_key
  resource_key_name             = var.resource_key_name
  resource_key_role             = var.resource_key_role
  generate_hmac_credentials     = var.generate_hmac_credentials
  cos_plan                      = var.cos_plan
  cos_tags                      = var.cos_tags
  access_tags                   = var.access_tags
}

locals {
  #  Add the cos instance id to the bucket configs
  bucket_configs = [
    for config in var.bucket_configs :
    {
      access_tags                   = config.access_tags
      bucket_name                   = config.bucket_name
      kms_encryption_enabled        = config.kms_encryption_enabled
      kms_guid                      = config.kms_guid
      kms_key_crn                   = config.kms_key_crn
      skip_iam_authorization_policy = config.skip_iam_authorization_policy
      management_endpoint_type      = config.management_endpoint_type
      cross_region_location         = config.cross_region_location
      storage_class                 = config.storage_class
      region_location               = config.region_location
      resource_instance_id          = module.cos_instance.cos_instance_id
      activity_tracking             = config.activity_tracking
      archive_rule                  = config.archive_rule
      expire_rule                   = config.expire_rule
      metrics_monitoring            = config.metrics_monitoring
      object_versioning             = config.object_versioning
      retention_rule                = config.retention_rule
      cbr_rules                     = config.cbr_rules
      single_site_location          = config.single_site_location
      force_delete                  = config.force_delete
      hard_quota                    = config.hard_quota
    }
  ]
}
module "buckets" {
  source         = "../../modules/buckets"
  bucket_configs = local.bucket_configs
}


locals {
  access_tags = [
    for tag in var.access_tags :
    {
      name     = split(":", tag)[0] # Extract tag_name
      value    = split(":", tag)[1] # Extract tag_value
      operator = "stringEquals"
    }
  ]
}

module "instance_cbr_rules" {
  depends_on       = [module.buckets]
  count            = length(var.instance_cbr_rules)
  source           = "terraform-ibm-modules/cbr/ibm//modules/cbr-rule-module"
  version          = "1.18.0"
  rule_description = var.instance_cbr_rules[count.index].description
  enforcement_mode = var.instance_cbr_rules[count.index].enforcement_mode
  rule_contexts    = var.instance_cbr_rules[count.index].rule_contexts
  resources = [{
    attributes = [
      {
        name     = "accountId"
        value    = var.instance_cbr_rules[count.index].account_id
        operator = "stringEquals"
      },
      {
        name     = "serviceInstance"
        value    = module.cos_instance.cos_instance_guid
        operator = "stringEquals"
      },
      {
        name     = "serviceName"
        value    = "cloud-object-storage"
        operator = "stringEquals"
      }
    ],
    tags = local.access_tags == null ? [] : local.access_tags
  }]
  operations = var.instance_cbr_rules[count.index].operations == null ? [{
    api_types = [
      {
        api_type_id = "crn:v1:bluemix:public:context-based-restrictions::::api-type:"
      }
    ]
  }] : var.instance_cbr_rules[count.index].operations
}

locals {
  instance_rule_ids = module.instance_cbr_rules[*].rule_id
  all_rule_ids      = concat(module.buckets.cbr_rule_ids, local.instance_rule_ids)
}
