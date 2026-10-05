# The existing SES user and its sender-identity permissions are managed
# outside this stack. Add only the configuration-set permission required
# by Plunk's SendRawEmail requests; preserve all existing policies.
resource "aws_iam_user_policy" "plunk_configuration_set_send" {
  name = "plunk-configuration-set-send-raw-email"
  user = "plunk-ses-sender"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowPlunkConfigurationSetRawEmail"
      Effect   = "Allow"
      Action   = "ses:SendRawEmail"
      Resource = "arn:aws:ses:us-east-1:483528439217:configuration-set/plunk-configuration-set"
    }]
  })
}
