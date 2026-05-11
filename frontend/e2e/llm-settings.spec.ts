import { test, expect } from '@playwright/test';

const API = 'http://localhost:3001';


test.describe('LLM 连接设置', () => {
  test('侧边栏模型状态区域可见', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByText('本地模型')).toBeVisible();
  });

  test('点击模型状态区域打开设置 Dialog', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    await expect(page.getByRole('dialog')).toBeVisible();
    await expect(page.getByText('LLM 连接设置')).toBeVisible();
  });

  test('Dialog 包含 Base URL、API Key 输入框和测试连接按钮', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByText('Base URL')).toBeVisible();
    await expect(dialog.getByText('API Key')).toBeVisible();
    await expect(dialog.getByRole('button', { name: '测试连接' })).toBeVisible();
  });

  test('Dialog 加载时显示已保存的 Base URL', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    const input = page.getByPlaceholder('http://localhost:8000/v1');

    await expect(input).not.toHaveValue('');
  });

  test('API Key 输入框默认为密码模式', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    const dialog = page.getByRole('dialog');
    const keyInput = dialog.locator('input[type="password"]');
    await expect(keyInput).toBeVisible();
  });

  test('点击眼睛图标切换 API Key 可见性', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.locator('input[type="password"]')).toBeVisible();
    await dialog.getByTestId('toggle-api-key-visibility').click();
    await expect(dialog.locator('input[type="password"]')).not.toBeVisible({ timeout: 1000 });
  });

  test('点击取消关闭 Dialog', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    await expect(page.getByRole('dialog')).toBeVisible();
    await page.getByRole('button', { name: '取消' }).click();
    await expect(page.getByRole('dialog')).not.toBeVisible();
  });

  test('测试连接按钮在有效输入时可点击', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    const dialog = page.getByRole('dialog');

    await expect(dialog.getByRole('button', { name: '测试连接' })).not.toBeDisabled();
  });

  test('Dialog 打开后自动显示当前模型，无需手动点测试连接', async ({ page, request }) => {

    const res = await request.get(`${API}/settings/llm`);
    const { model } = await res.json() as { model: string };

    await page.goto('/');
    await page.getByText('本地模型').click();
    const dialog = page.getByRole('dialog');


    await expect(dialog.getByText(model)).toBeVisible({ timeout: 10000 });
  });

  test('测试连接完成后显示结果（模型列表或错误）', async ({ page }) => {
    await page.goto('/');
    await page.getByText('本地模型').click();
    const dialog = page.getByRole('dialog');

    await dialog.getByRole('button', { name: '测试连接' }).click();
    await expect(dialog.getByText('连接中...')).not.toBeVisible({ timeout: 15000 });
    await expect(dialog.getByText('测试连接')).toBeVisible();
  });

  test('保存配置：PUT /settings/llm 不报 JSON parse 错误', async ({ page, request }) => {

    const res = await request.put(`${API}/settings/llm`, {
      data: {
        baseUrl: 'http://host.docker.internal:8000/v1',
        apiKey: '1234',
        model: 'test-model',
      },
    });

    expect(res.status()).toBeLessThan(400);


    const cfg = await request.get(`${API}/settings/llm`);
    const body = await cfg.json() as { baseUrl: string; apiKey: string; model: string };
    expect(body.baseUrl).toBeTruthy();
    expect(body.model).toBeTruthy();
  });

  test('GET /settings/llm 返回完整 LLM 配置', async ({ request }) => {
    const res = await request.get(`${API}/settings/llm`);
    expect(res.status()).toBe(200);
    const body = await res.json() as Record<string, string>;
    expect(body).toHaveProperty('baseUrl');
    expect(body).toHaveProperty('apiKey');
    expect(body).toHaveProperty('model');
  });

  test('GET /settings/llm/models 使用已保存配置返回模型列表', async ({ request }) => {
    const res = await request.get(`${API}/settings/llm/models`);

    if (res.status() === 200) {
      const body = await res.json() as { models: string[] };
      expect(Array.isArray(body.models)).toBe(true);
    } else {

      test.skip(res.status() >= 500, 'LLM 离线，跳过模型列表测试');
    }
  });
});
