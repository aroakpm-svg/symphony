defmodule SymphonyElixir.SecretSafety do
  @moduledoc false

  @secret_patterns [
    ~r/(?i)(authorization|bearer|credential|password|secret|api[_-]?key|token)\s*[:= ]/,
    ~r/(?i)(^|[_:\/-])(credential|password|secret|api[_-]?key|token)([_:\/-]|$)/,
    ~r/(?i)\bsk-(?:proj-)?[a-z0-9_-]{16,}\b/,
    ~r/(?i)\bgh[pousr]_[a-z0-9]{20,}\b/,
    ~r/(?i)\bgithub_pat_[a-z0-9_]{20,}\b/,
    ~r/\b(?:AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b/,
    ~r/(?i)\bxox[baprs]-[a-z0-9-]{20,}\b/,
    ~r/\bAIza[0-9A-Za-z_-]{20,}\b/,
    ~r/(?i)\b[rs]k_(?:live|test)_[a-z0-9]{16,}\b/,
    ~r/(?i)\b(?:glpat-|npm_|pypi-|hf_)[a-z0-9_-]{20,}\b/,
    ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
    ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
    ~r|(?i)://[^/@\s]+:[^/@\s]+@|
  ]

  @spec contains_secret?(String.t()) :: boolean()
  def contains_secret?(value) when is_binary(value) do
    Enum.any?(@secret_patterns, &Regex.match?(&1, value))
  end
end
