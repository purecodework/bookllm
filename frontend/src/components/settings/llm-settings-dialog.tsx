"use client";

import { useState, useEffect, useCallback } from "react";
import { Loader2 } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Separator } from "@/components/ui/separator";
import { ApiKeyField } from "@/components/settings/shared/api-key-field";
import { ConnectionTestButton } from "@/components/settings/shared/connection-test-button";
import { ModelList } from "@/components/settings/shared/model-list";
import { type TestState } from "@/components/settings/types";
import {
  getLlmConfig,
  saveLlmConfig,
  testLlmConnection,
  type LlmConfig,
} from "@/lib/api";
import { useI18n } from "@/lib/i18n";

interface LlmSettingsDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved?: () => void;
}

export function LlmSettingsDialog({
  open,
  onOpenChange,
  onSaved,
}: LlmSettingsDialogProps) {
  const { t } = useI18n();
  const [baseUrl, setBaseUrl] = useState("");
  const [apiKey, setApiKey] = useState("");
  const [apiKeyMask, setApiKeyMask] = useState("");
  const [apiKeyConfigured, setApiKeyConfigured] = useState(false);
  const [model, setModel] = useState("");
  const [showKey, setShowKey] = useState(false);

  const [testState, setTestState] = useState<TestState>("idle");
  const [testError, setTestError] = useState("");
  const [models, setModels] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [loadingConfig, setLoadingConfig] = useState(false);
  const [saveError, setSaveError] = useState("");

  const loadConfig = useCallback(async () => {
    setLoadingConfig(true);
    try {
      const cfg = await getLlmConfig();
      setBaseUrl(cfg.baseUrl);
      setApiKey("");
      setApiKeyMask(cfg.apiKey);
      setApiKeyConfigured(cfg.apiKeyConfigured ?? false);
      setModel(cfg.model);
      setLoadingConfig(false);
      try {

        const res = await testLlmConnection(cfg.baseUrl, "");
        setModels(res.models);
        setTestState("ok");
      } catch {}
    } catch {
      setLoadingConfig(false);
    }
  }, []);

  useEffect(() => {
    if (open) {
      void loadConfig();
      setTestState("idle");
      setModels([]);
      setTestError("");
      setSaveError("");
      setApiKey("");
    }
  }, [open, loadConfig]);

  const handleTest = async () => {
    setTestState("loading");
    setTestError("");
    setModels([]);
    try {
      const res = await testLlmConnection(baseUrl, apiKey);
      setModels(res.models);
      setTestState("ok");
      if (res.models.length > 0 && !res.models.includes(model)) {
        setModel(res.models[0]);
      }
    } catch (e) {
      setTestError(e instanceof Error ? e.message : t("llm.connectionFailed"));
      setTestState("error");
    }
  };

  const handleSave = async () => {
    setSaving(true);
    setSaveError("");
    try {
      await saveLlmConfig({
        baseUrl,
        apiKey,
        model,
      } satisfies Partial<LlmConfig>);
      onSaved?.();
      onOpenChange(false);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : t("llm.saveFailed"));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{t("llm.title")}</DialogTitle>
          <DialogDescription className="sr-only">
            {t("sidebar.configureConnection")}
          </DialogDescription>
        </DialogHeader>

        {loadingConfig ? (
          <div className="flex justify-center py-8">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        ) : (
          <div className="space-y-5 py-1">
            <div className="space-y-1.5">
              <label className="text-xs font-medium text-muted-foreground">
                {t("llm.baseUrlLabel")}
              </label>
              <Input
                value={baseUrl}
                onChange={(e) => {
                  setBaseUrl(e.target.value);
                  setTestState("idle");
                }}
                placeholder={t("llm.baseUrlPlaceholder")}
                className="font-mono text-sm"
              />
            </div>

            <div className="space-y-1.5">
              <label className="text-xs font-medium text-muted-foreground">
                {t("llm.apiKeyLabel")}
              </label>
              <ApiKeyField
                value={apiKey}
                onChange={(value) => {
                  setApiKey(value);
                  setTestState("idle");
                }}
                configured={apiKeyConfigured}
                mask={apiKeyConfigured ? apiKeyMask : ""}
                show={showKey}
                onToggleShow={() => setShowKey((v) => !v)}
                testId="toggle-api-key-visibility"
              />
            </div>

            <ConnectionTestButton
              state={testState}
              error={testError}
              disabled={!baseUrl || (!apiKey && !apiKeyConfigured)}
              onTest={handleTest}
            />

            {(models.length > 0 || testState === "ok") && (
              <>
                <Separator />
                <div className="space-y-1.5">
                  <label className="text-xs font-medium text-muted-foreground">
                    {t("llm.modelLabel")}
                  </label>
                  <ModelList
                    models={models}
                    selectedModel={model}
                    onSelect={setModel}
                    maxHeightClass="max-h-[220px]"
                  />
                </div>
              </>
            )}

            <Separator />
            <p className="text-[11px] text-muted-foreground/80">
              {t("llm.paramsHint")}
            </p>
            {saveError && (
              <p className="text-xs text-destructive" role="alert">
                {saveError}
              </p>
            )}
          </div>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button onClick={handleSave} disabled={saving || !model}>
            {saving && <Loader2 className="h-3.5 w-3.5 animate-spin mr-1.5" />}
            {t("common.save")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
