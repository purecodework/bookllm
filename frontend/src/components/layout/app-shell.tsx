import { Sidebar } from "./sidebar";
import { Header } from "./header";

interface AppShellProps {
  children: React.ReactNode;

  headerTitle?: string;
  headerSearchValue?: string;
  onHeaderSearchChange?: (value: string) => void;
  headerSearchPlaceholder?: string;
}

export function AppShell({
  children,
  headerTitle,
  headerSearchValue,
  onHeaderSearchChange,
  headerSearchPlaceholder,
}: AppShellProps) {
  return (
    <div className="min-h-screen bg-transparent">
      <Sidebar />

      <Header
        title={headerTitle}
        searchValue={headerSearchValue}
        onSearchChange={onHeaderSearchChange}
        searchPlaceholder={headerSearchPlaceholder}
      />

      <main className="min-h-screen pt-[var(--header-height)] pb-20 md:pb-0 lg:pl-[var(--sidebar-width)]">
        <div className="h-full">{children}</div>
      </main>
    </div>
  );
}
