locals {
  host_ip_file                 = "${local.shared_volume_container_path}/host_ip"
  task_revision_file           = "${local.shared_volume_container_path}/task_revision"
  hosts_folder                 = "${local.shared_volume_container_path}/hosts"
  s3_revision_folder           = "${local.quorum_bucket}/rev_$TASK_REVISION"
  export_task_revision_command = "export TASK_REVISION=$(curl -s 169.254.170.2/v2/metadata | jq '.Revision' -r)"
  export_host_ip_command       = "export HOST_IP=$(curl -s 169.254.170.2/v2/metadata | jq '.Containers[] | select(.Name == \"config-bootstrap\") | .Networks[] | select(.NetworkMode == \"awsvpc\") | .IPv4Addresses[0]' -r )"
  normalized_host_ip           = "ip_$(echo $HOST_IP | sed -e 's/\\./_/g')"

  node_key_bootstrap_commands = [
    "mkdir -p ${local.quorum_data_dir}/geth",
    "mkdir -p ${local.node_ids_folder}",
    "echo \"\" > ${local.quorum_password_file}",
    "bootnode -genkey ${local.quorum_data_dir}/geth/nodekey",
    "export NODE_ID=$(bootnode -nodekey ${local.quorum_data_dir}/geth/nodekey -writeaddress)",
    "echo $NODE_ID > ${local.node_id_file}",
  ]

  node_key_bootstrap_container_definition = {
    name      = "${local.node_key_bootstrap_container_name}"
    image     = "${local.quorum_docker_image}"
    essential = "false"

    logConfiguration = {
      logDriver = "awslogs"

      options = {
        awslogs-group         = "${aws_cloudwatch_log_group.quorum.name}"
        awslogs-region        = "${var.region}"
        awslogs-stream-prefix = "${var.deployment_id}"
      }
    }

    mountPoints = [
      {
        sourceVolume  = "${local.shared_volume_name}"
        containerPath = "${local.shared_volume_container_path}"
      },
    ]

    healthCheck = {
      interval = 5
      retries  = 10

      command = [
        "CMD-SHELL",
        "[ -S ${local.node_id_file} ];",
      ]
    }

    entrypoint = [
      "/bin/sh",
      "-c",
      "${join("\n", local.node_key_bootstrap_commands)}",
    ]

    dockerLabels = "${local.common_tags}"
  }

  metadata_bootstrap_commands = [
    "apk update",
    "apk add curl jq",
    "echo $(curl -s 169.254.170.2/v2/metadata)",
    "echo $(curl -s localhost:51678/v1/metadata)",
    "${local.export_task_revision_command}",
    "echo \"Task Revision: $TASK_REVISION\"",
    "echo $TASK_REVISION > ${local.task_revision_file}",
    "${local.export_host_ip_command}",
    "echo \"Host IP: $HOST_IP\"",
    "echo $HOST_IP > ${local.host_ip_file}",
    "mkdir -p ${local.hosts_folder}",
    "aws s3 cp ${local.host_ip_file} s3://${local.s3_revision_folder}/hosts/${local.normalized_host_ip} --sse aws:kms --sse-kms-key-id ${var.quorum_bucket_kms_key_arn}",
    "count=0; while [ $count -lt ${var.number_of_nodes} ]; do aws s3 cp --recursive s3://${local.s3_revision_folder}/hosts ${local.hosts_folder}; count=$(ls ${local.hosts_folder} | grep ^ip | wc -l); echo \"Wait for other containers to report their IPs ... $count/${var.number_of_nodes}\"; sleep 3; done",
    "echo \"All containers have reported their IPs\"",
    "aws s3 cp ${local.node_id_file} s3://${local.s3_revision_folder}/nodeids/${local.normalized_host_ip} --sse aws:kms --sse-kms-key-id ${var.quorum_bucket_kms_key_arn}",
    "count=0; while [ $count -lt ${var.number_of_nodes} ]; do aws s3 cp --recursive s3://${local.s3_revision_folder}/nodeids ${local.node_ids_folder}; count=$(ls ${local.node_ids_folder} | grep ^ip | wc -l); echo \"Wait for other nodes to report their IDs ... $count/${var.number_of_nodes}\"; sleep 3; done",
    "echo \"All nodes have registered their IDs\"",
  ]

  metadata_bootstrap_container_definition = {
    name      = "${local.metadata_bootstrap_container_name}"
    image     = "${local.aws_cli_docker_image}"
    essential = "false"

    logConfiguration = {
      logDriver = "awslogs"

      options = {
        awslogs-group         = "${aws_cloudwatch_log_group.quorum.name}"
        awslogs-region        = "${var.region}"
        awslogs-stream-prefix = "${var.deployment_id}"
      }
    }

    mountPoints = [
      {
        sourceVolume  = "${local.shared_volume_name}"
        containerPath = "${local.shared_volume_container_path}"
      },
    ]

    volumesFrom = [
      {
        sourceContainer = "${local.node_key_bootstrap_container_name}"
      },
    ]

    healthCheck = {
      interval = 5
      retries  = 10

      command = [
        "CMD-SHELL",
        "[ -S ${local.host_ip_file} ];",
      ]
    }

    entryPoint = [
      "/bin/sh",
      "-c",
      "${join("\n", local.metadata_bootstrap_commands)}",
    ]

    dockerLabels = "${local.common_tags}"
  }
}