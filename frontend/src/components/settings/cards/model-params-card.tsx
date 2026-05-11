"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { FieldLabel } from "@/components/settings/shared/field-label";
import { useI18n } from "@/lib/i18n";

export function RequestTimeoutCard({
  timeoutSeconds,
  setTimeoutSeconds,
}: {
  timeoutSeconds: string;
  setTimeoutSeconds: (value: string) => void;
}) {
  const { t } = useI18n();
  return (
    <Card>
      <CardHeader className="border-b border-border pb-3">
        <CardTitle className="text-sm font-semibold">{t("settings.requestTimeout")}</CardTitle>
      </CardHeader>
      <CardContent className="pt-6">
        <div className="space-y-1.5">
          <FieldLabel label={t("settings.requestTimeout")} hint={t("settings.seconds")} />
          <Input
            type="number"
            min={1}
            value={timeoutSeconds}
            onChange={(e) => setTimeoutSeconds(e.target.value)}
            className="font-mono text-sm"
          />
        </div>
      </CardContent>
    </Card>
  );
}
