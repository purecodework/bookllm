"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { GlassToggle } from "@/components/ui/glass-toggle";
import { Input } from "@/components/ui/input";
import { ApiKeyField } from "@/components/settings/shared/api-key-field";
import { ConnectionTestButton } from "@/components/settings/shared/connection-test-button";
import { FieldLabel } from "@/components/settings/shared/field-label";
import { ModelList, SelectedModelPill } from "@/components/settings/shared/model-list";
import { type TestState } from "@/components/settings/types";
import { type SidekickConfig } from "@/lib/api";
import { useI18n } from "@/lib/i18n";

export function SidekickConnectionCard({
  sidekick,
  setSidekick,
  apiKeyConfigured,
  apiKeyMask,
  showApiKey,
  setShowApiKey,
  testState,
  testError,
  models,
  onTest,
}: {
  sidekick: SidekickConfig;
  setSidekick: (updater: (value: SidekickConfig) => SidekickConfig) => void;
  apiKeyConfigured: boolean;
  apiKeyMask: string;
  showApiKey: boolean;
  setShowApiKey: (value: boolean | ((value: boolean) => boolean)) => void;
  testState: TestState;
  testError: string;
  models: string[];
  onTest: () => void;
}) {
  const { t } = useI18n();
  return (
    <Card>
      <CardHeader className="border-b border-border pb-3">
        <CardTitle className="text-sm font-semibold">
          {t("settings.sidekickConnectionTitle")}
        </CardTitle>
        <p className="mt-0.5 text-xs text-muted-foreground">
          {t("settings.sidekickConnectionDesc")}
        </p>
      </CardHeader>

      <CardContent className="space-y-4 pt-4">
        <GlassToggle
          checked={sidekick.enabled}
          onChange={(enabled) => setSidekick((s) => ({ ...s, enabled }))}
          label={t("settings.sidekickConnectionToggle")}
        />

        {sidekick.enabled && (
          <div className="space-y-4">
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div className="space-y-1.5">
                <FieldLabel label={t("settings.sidekickBaseUrl")} />
                <Input
                  value={sidekick.baseUrl}
                  onChange={(e) => setSidekick((s) => ({ ...s, baseUrl: e.target.value }))}
                  placeholder="https://api.openai.com/v1"
                  className="font-mono text-sm"
                />
              </div>

              <div className="space-y-1.5">
                <FieldLabel label={t("settings.sidekickApiKey")} />
                <ApiKeyField
                  value={sidekick.apiKey}
                  onChange={(apiKey) => setSidekick((s) => ({ ...s, apiKey }))}
                  configured={apiKeyConfigured}
                  mask={apiKeyMask}
                  show={showApiKey}
                  onToggleShow={() => setShowApiKey((v) => !v)}
                />
              </div>
            </div>

            <ConnectionTestButton
              state={testState}
              error={testError}
              disabled={!sidekick.baseUrl || (!sidekick.apiKey && !apiKeyConfigured)}
              onTest={onTest}
            />

            {models.length > 0 ? (
              <div className="space-y-1.5">
                <FieldLabel label={t("settings.sidekickModel")} />
                <ModelList
                  models={models}
                  selectedModel={sidekick.model}
                  onSelect={(model) => setSidekick((s) => ({ ...s, model }))}
                />
              </div>
            ) : sidekick.model ? (
              <div className="space-y-1.5">
                <FieldLabel label={t("settings.sidekickModel")} />
                <SelectedModelPill model={sidekick.model} />
              </div>
            ) : null}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
