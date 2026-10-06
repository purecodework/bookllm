"""Token usage is authoritative; estimates only bound the pre-dispatch reservation."""
from dataclasses import dataclass
import math


@dataclass(frozen=True)
class TokenUsage:
    prompt_tokens: int
    completion_tokens: int

    def __post_init__(self):
        if type(self.prompt_tokens) is not int or type(self.completion_tokens) is not int or self.prompt_tokens < 0 or self.completion_tokens < 0 or self.prompt_tokens + self.completion_tokens <= 0:
            raise ValueError("Invalid token usage")

    @classmethod
    def from_provider(cls, value):
        if not isinstance(value, dict):
            raise ValueError("Missing provider token usage")
        prompt, completion = value.get("prompt_tokens"), value.get("completion_tokens")
        # bool is an int subclass; never accept it as a usage count.
        if type(prompt) is not int or type(completion) is not int or prompt < 0 or completion < 0 or prompt + completion <= 0:
            raise ValueError("Invalid provider token usage")
        total = value.get("total_tokens", prompt + completion)
        if type(total) is not int or total != prompt + completion:
            raise ValueError("Inconsistent provider token usage")
        return cls(prompt, completion)

    def points(self, tokens_per_point):
        if tokens_per_point <= 0:
            raise ValueError("Invalid token pricing")
        return max(1, (self.prompt_tokens + self.completion_tokens + tokens_per_point - 1) // tokens_per_point)

    def as_dict(self):
        return {"prompt_tokens": self.prompt_tokens, "completion_tokens": self.completion_tokens, "total_tokens": self.prompt_tokens + self.completion_tokens}


class UsageText(str):
    def __new__(cls, text, usage):
        value = super().__new__(cls, text)
        value.usage = usage
        return value


class UsageTerms(list):
    def __init__(self, terms, usage):
        super().__init__(terms)
        self.usage = usage


@dataclass(frozen=True)
class TokenBudget:
    estimated_input_tokens: int
    minimum_output_tokens: int
    desired_output_tokens: int
    tokens_per_point: int

    @classmethod
    def for_request(cls, settings, messages, source, operation, *, entity_query=False, capture=False):
        # UTF-8 bytes / 3 is deliberately cautious for ordinary DeepSeek prose, but is
        # not a tokenizer. Provider-reported usage is always settled, even when higher.
        input_tokens = 12 + sum(12 + math.ceil(len(message["content"].encode("utf-8")) / 3) for message in messages)
        source_estimate = math.ceil(len(source.encode("utf-8")) / 3)
        minimum = settings.minimum_output_tokens if operation == "glossary" else max(settings.minimum_output_tokens, source_estimate)
        desired = max(minimum, min(2048, source_estimate * 2)) if operation == "glossary" else max(minimum, source_estimate * 2)
        # Compact entity queries need bounded metadata output; initial translation
        # trailers reserve headroom but still settle solely on reported token usage.
        if operation == "glossary" and entity_query:
            desired = min(3072, max(1536, desired))
        if operation != "glossary" and capture:
            desired += 768
        return cls(input_tokens, min(settings.max_output_tokens, minimum), min(settings.max_output_tokens, desired), settings.tokens_per_point)

    def fit(self, available_points):
        available_output = available_points * self.tokens_per_point - self.estimated_input_tokens
        if available_output < self.minimum_output_tokens:
            return None
        max_tokens = min(self.desired_output_tokens, available_output)
        reservation = max(1, (self.estimated_input_tokens + max_tokens + self.tokens_per_point - 1) // self.tokens_per_point)
        return reservation, max_tokens


@dataclass(frozen=True)
class TokenReservation:
    max_tokens: int = 0
    cached: object | None = None
