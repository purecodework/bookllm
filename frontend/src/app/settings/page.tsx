"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AppShell } from "@/components/layout/app-shell";
import {
  BookGlossaryCard,
  CustomStyleCard,
  LoadingSettingsCard,
  RequestTimeoutCard,
  ReviewCard,
  SettingsSaveBar,
  SidekickConnectionCard,
  TranslationParamsCard,
  type ModelSource,
  type TestState,
} from "@/components/settings/settings-cards";
import { TranslationPipeline } from "@/components/settings/translation-pipeline";
import { useI18n } from "@/lib/i18n";
import {
  getLlmConfig,
  getSidekickConfig,
  getTranslationConfig,
  saveLlmConfig,
  saveSidekickConfig,
  saveTranslationConfig,
  testSidekickConnection,
  type SidekickConfig,
} from "@/lib/api";

export default function SettingsPage() {
  const { t } = useI18n();
  const [model, setModel] = useState("");
  const [timeoutSeconds, setTimeoutSeconds] = useState("60");

  const [inputTokenBudget, setInputTokenBudget] = useState("2000");
  const [concurrency, setConcurrency] = useState("1");
  const [styleEnabled, setStyleEnabled] = useState(false);
  const [stylePrompt, setStylePrompt] = useState("");
  const [polishModelSource, setPolishModelSource] =
    useState<ModelSource>("primary");
  const [glossaryEnabled, setGlossaryEnabled] = useState(false);
  const [glossaryModelSource, setGlossaryModelSource] =
    useState<ModelSource>("primary");
  const [reviewEnabled, setReviewEnabled] = useState(false);
  const [reviewModelSource, setReviewModelSource] =
    useState<ModelSource>("primary");

  const [sidekick, setSidekick] = useState<SidekickConfig>({
    enabled: false,
    baseUrl: "",
    apiKey: "",
    model: "",
    proofreadEnabled: false,
    polishEnabled: false,
  });
  const [sidekickApiKeyConfigured, setSidekickApiKeyConfigured] =
    useState(false);
  const [sidekickApiKeyMask, setSidekickApiKeyMask] = useState("");
  const [showSidekickKey, setShowSidekickKey] = useState(false);
  const [sidekickTestState, setSidekickTestState] = useState<TestState>("idle");
  const [sidekickTestError, setSidekickTestError] = useState("");
  const [sidekickModels, setSidekickModels] = useState<string[]>([]);

  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState("");
  const [saveSuccess, setSaveSuccess] = useState("");

  const concurrencyValue = Math.min(
    32,
    Math.max(1, Number.parseInt(concurrency, 10) || 1),
  );

  const sidekickReady = useMemo(
    () =>
      sidekick.enabled
      && !!sidekick.baseUrl
      && !!sidekick.model
      && (sidekickApiKeyConfigured || !!sidekick.apiKey),
    [
      sidekick.enabled,
      sidekick.baseUrl,
      sidekick.model,
      sidekickApiKeyConfigured,
      sidekick.apiKey,
    ],
  );

  const loadConfig = useCallback(async () => {
    setLoading(true);
    setSaveError("");
    try {
      const [llm, translation] = await Promise.all([
        getLlmConfig(),
        getTranslationConfig(),
      ]);

      setModel(llm.model);
      setTimeoutSeconds(
        String(Math.max(1, Math.round((llm.timeoutMs ?? 60000) / 1000))),
      );

      setInputTokenBudget(String(translation.inputTokenBudget ?? 2000));
      setConcurrency(String(translation.concurrency ?? 1));
      setStyleEnabled(Boolean(translation.styleEnabled));
      setStylePrompt(translation.stylePrompt ?? "");
      setPolishModelSource(
        translation.polishModelSource === "sidekick" ? "sidekick" : "primary",
      );
      setGlossaryEnabled(Boolean(translation.glossaryEnabled));
      setGlossaryModelSource(
        translation.glossaryModelSource === "sidekick" ? "sidekick" : "primary",
      );
      setReviewEnabled(Boolean(translation.reviewEnabled));
      setReviewModelSource(
        translation.reviewModelSource === "sidekick" ? "sidekick" : "primary",
      );

      try {
        const sk = await getSidekickConfig();
        setSidekick({ ...sk, apiKey: "", polishEnabled: false });
        setSidekickApiKeyConfigured(sk.apiKeyConfigured ?? false);
        setSidekickApiKeyMask(sk.apiKey ?? "");
      } catch {

      }
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : t("settings.loadFailed"));
    } finally {
      setLoading(false);
    }
  }, [t]);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  const handleSidekickTest = async () => {
    setSidekickTestState("loading");
    setSidekickTestError("");
    setSidekickModels([]);
    try {
      const res = await testSidekickConnection(sidekick.baseUrl, sidekick.apiKey);
      setSidekickModels(res.models);
      setSidekickTestState("ok");
      if (res.models.length > 0 && !res.models.includes(sidekick.model)) {
        setSidekick((s) => ({ ...s, model: res.models[0] }));
      }
    } catch (e) {
      setSidekickTestError(
        e instanceof Error ? e.message : t("llm.connectionFailed"),
      );
      setSidekickTestState("error");
    }
  };

  const handleSave = async () => {
    setSaving(true);
    setSaveError("");
    setSaveSuccess("");
    try {
      await Promise.all([
        saveLlmConfig({
          model,
          timeoutMs: Math.max(
            1000,
            Math.round((Number.parseFloat(timeoutSeconds) || 60) * 1000),
          ),
        }),
        saveTranslationConfig({
          inputTokenBudget: Math.max(
            1024,
            Number.parseInt(inputTokenBudget, 10) || 1024,
          ),
          concurrency: Math.min(
            32,
            Math.max(1, Number.parseInt(concurrency, 10) || 1),
          ),
          styleEnabled,
          stylePrompt,
          polishModelSource:
            styleEnabled && sidekickReady && polishModelSource === "sidekick"
              ? "sidekick"
              : "primary",
          glossaryEnabled,
          glossaryModelSource:
            glossaryEnabled && sidekickReady && glossaryModelSource === "sidekick"
              ? "sidekick"
              : "primary",
          reviewEnabled,
          reviewModelSource:
            reviewEnabled && sidekickReady && reviewModelSource === "sidekick"
              ? "sidekick"
              : "primary",
        }),
        saveSidekickConfig({
          ...sidekick,
          proofreadEnabled: false,
          polishEnabled: false,
        }),
      ]);
      setSaveSuccess(t("settings.saved"));
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : t("settings.saveFailed"));
    } finally {
      setSaving(false);
    }
  };

  return (
    <AppShell headerTitle={t("common.settings")}>
      <div className="mx-auto max-w-3xl space-y-6 p-4 md:p-8">
        <div>
          <h1 className="text-[24px] font-semibold tracking-tight">
            {t("settings.pageTitle")}
          </h1>
        </div>

        {loading ? (
          <LoadingSettingsCard />
        ) : (
          <>
            <SidekickConnectionCard
              sidekick={sidekick}
              setSidekick={(updater) => {
                setSidekick(updater);
                setSidekickTestState("idle");
                setSidekickModels([]);
              }}
              apiKeyConfigured={sidekickApiKeyConfigured}
              apiKeyMask={sidekickApiKeyMask}
              showApiKey={showSidekickKey}
              setShowApiKey={setShowSidekickKey}
              testState={sidekickTestState}
              testError={sidekickTestError}
              models={sidekickModels}
              onTest={handleSidekickTest}
            />

            <TranslationPipeline
              title={t("settings.pipelineTitle")}
              steps={[
                {
                  id: "glossary",
                  active: glossaryEnabled,
                  content: (
                    <BookGlossaryCard
                      enabled={glossaryEnabled}
                      onEnabledChange={setGlossaryEnabled}
                      modelSource={glossaryModelSource}
                      onModelSourceChange={setGlossaryModelSource}
                      sidekickReady={sidekickReady}
                    />
                  ),
                },
                {
                  id: "review",
                  active: reviewEnabled,
                  content: (
                    <ReviewCard
                      enabled={reviewEnabled}
                      onEnabledChange={setReviewEnabled}
                      modelSource={reviewModelSource}
                      onModelSourceChange={setReviewModelSource}
                      sidekickReady={sidekickReady}
                    />
                  ),
                },
                {
                  id: "polish",
                  active: styleEnabled,
                  content: (
                    <CustomStyleCard
                      enabled={styleEnabled}
                      onEnabledChange={setStyleEnabled}
                      modelSource={polishModelSource}
                      onModelSourceChange={setPolishModelSource}
                      prompt={stylePrompt}
                      onPromptChange={setStylePrompt}
                      sidekickReady={sidekickReady}
                    />
                  ),
                },
              ]}
            />

            <TranslationParamsCard
              inputTokenBudget={inputTokenBudget}
              setInputTokenBudget={setInputTokenBudget}
              concurrencyValue={concurrencyValue}
              setConcurrency={setConcurrency}
            />

            <RequestTimeoutCard
              timeoutSeconds={timeoutSeconds}
              setTimeoutSeconds={setTimeoutSeconds}
            />

            <SettingsSaveBar
              saving={saving}
              disabled={!model}
              error={saveError}
              success={saveSuccess}
              onSave={handleSave}
            />
          </>
        )}
      </div>
    </AppShell>
  );
}
