import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import SettingsPage from "@/app/settings/page";
import {
  getLlmConfig,
  getSidekickConfig,
  getTranslationConfig,
  saveLlmConfig,
  saveSidekickConfig,
  saveTranslationConfig,
  testSidekickConnection,
} from "@/lib/api";

jest.mock("@/components/layout/app-shell", () => ({
  AppShell: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}));

const mockT = (key: string) => key;

jest.mock("@/lib/i18n", () => ({
  useI18n: () => ({ t: mockT }),
}));

jest.mock("@/lib/api", () => ({
  getLlmConfig: jest.fn(),
  saveLlmConfig: jest.fn(),
  getTranslationConfig: jest.fn(),
  saveTranslationConfig: jest.fn(),
  getSidekickConfig: jest.fn(),
  saveSidekickConfig: jest.fn(),
  testSidekickConnection: jest.fn(),
}));

const mockedGetLlmConfig = getLlmConfig as jest.MockedFunction<typeof getLlmConfig>;
const mockedGetTranslationConfig = getTranslationConfig as jest.MockedFunction<typeof getTranslationConfig>;
const mockedGetSidekickConfig = getSidekickConfig as jest.MockedFunction<typeof getSidekickConfig>;
const mockedSaveLlmConfig = saveLlmConfig as jest.MockedFunction<typeof saveLlmConfig>;
const mockedSaveTranslationConfig = saveTranslationConfig as jest.MockedFunction<typeof saveTranslationConfig>;
const mockedSaveSidekickConfig = saveSidekickConfig as jest.MockedFunction<typeof saveSidekickConfig>;
const mockedTestSidekickConnection = testSidekickConnection as jest.MockedFunction<typeof testSidekickConnection>;

describe("SettingsPage", () => {
  beforeEach(() => {
    jest.clearAllMocks();

    mockedGetLlmConfig.mockResolvedValue({
      baseUrl: "https://api.openai.com/v1",
      apiKey: "",
      apiKeyConfigured: true,
      model: "gpt-4o-mini",
      temperature: 0.2,
      temperatureEnabled: false,
      timeoutMs: 60000,
    });
    mockedGetTranslationConfig.mockResolvedValue({
      inputTokenBudget: 2000,
      contextWindowTokens: 8192,
      concurrency: 1,
      styleEnabled: false,
      stylePrompt: "",
      polishModelSource: "primary",
      glossaryEnabled: false,
      glossaryModelSource: "primary",
      reviewEnabled: false,
      reviewModelSource: "primary",
    });
    mockedGetSidekickConfig.mockResolvedValue({
      enabled: true,
      baseUrl: "https://api.openai.com/v1",
      apiKey: "sk-ab••••••••wxyz",
      apiKeyConfigured: true,
      model: "gpt-4o-mini",
      proofreadEnabled: true,
      polishEnabled: false,
    });
    mockedSaveLlmConfig.mockResolvedValue(undefined);
    mockedSaveTranslationConfig.mockResolvedValue(undefined);
    mockedSaveSidekickConfig.mockResolvedValue(undefined);
    mockedTestSidekickConnection.mockResolvedValue({ models: ["gpt-4o-mini"], provider: "OpenAI" });
  });

  it("persists sidekick connection disabled state when using the global settings save button", async () => {
    render(<SettingsPage />);

    await screen.findByText("settings.sidekickConnectionToggle");

    fireEvent.click(screen.getByText("settings.sidekickConnectionToggle"));
    fireEvent.click(screen.getByRole("button", { name: "settings.saveButton" }));

    await waitFor(() => {
      expect(mockedSaveSidekickConfig).toHaveBeenCalledWith(
        expect.objectContaining({
          enabled: false,
          proofreadEnabled: false,
          polishEnabled: false,
        }),
      );
    });
  });

  it("renders first-time advanced translation features disabled by default", async () => {
    mockedGetTranslationConfig.mockResolvedValueOnce({
      inputTokenBudget: 2000,
      contextWindowTokens: 8192,
      concurrency: 1,
      styleEnabled: false,
      stylePrompt: "",
      polishModelSource: "primary",
      glossaryEnabled: false,
      glossaryModelSource: "primary",
      reviewEnabled: false,
      reviewModelSource: "primary",
    });
    mockedGetSidekickConfig.mockResolvedValueOnce({
      enabled: false,
      baseUrl: "",
      apiKey: "",
      apiKeyConfigured: false,
      model: "",
      proofreadEnabled: false,
      polishEnabled: false,
    });

    render(<SettingsPage />);

    await screen.findByText("settings.sidekickConnectionToggle");

    const switches = screen.getAllByRole("switch");
    expect(switches).toHaveLength(4);
    expect(switches.every((node) => node.getAttribute("aria-checked") === "false")).toBe(true);
  });

  it("falls back glossary model selection to primary when sidekick is unavailable", async () => {
    mockedGetTranslationConfig.mockResolvedValueOnce({
      inputTokenBudget: 2000,
      contextWindowTokens: 8192,
      concurrency: 1,
      styleEnabled: false,
      stylePrompt: "",
      polishModelSource: "primary",
      glossaryEnabled: true,
      glossaryModelSource: "sidekick",
      reviewEnabled: false,
      reviewModelSource: "primary",
    });
    mockedGetSidekickConfig.mockResolvedValueOnce({
      enabled: false,
      baseUrl: "https://api.openai.com/v1",
      apiKey: "sk-ab••••••••wxyz",
      apiKeyConfigured: true,
      model: "gpt-4o-mini",
      proofreadEnabled: false,
      polishEnabled: false,
    });

    render(<SettingsPage />);

    await screen.findByText("settings.saveButton");
    fireEvent.click(screen.getByRole("button", { name: "settings.saveButton" }));

    await waitFor(() => {
      expect(mockedSaveTranslationConfig).toHaveBeenCalledWith(
        expect.objectContaining({
          glossaryEnabled: true,
          glossaryModelSource: "primary",
        }),
      );
    });
  });
});
