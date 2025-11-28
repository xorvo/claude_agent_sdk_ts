import Config

# Default configuration for ClaudeAgentSdkTs
# These can be overridden in environment-specific config files

config :claude_agent_sdk_ts,
  # Use AWS Bedrock for Claude access
  use_bedrock: true,

  # AWS region for Bedrock
  aws_region: "us-east-1",

  # Maximum tokens in response
  max_tokens: 4096,

  # Request timeout in milliseconds (5 minutes)
  timeout: 300_000

# Import environment specific config
import_config "#{config_env()}.exs"
