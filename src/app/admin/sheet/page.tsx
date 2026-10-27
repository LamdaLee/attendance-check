import AdminShell from "@/components/AdminShell";
import SheetBoard from "@/components/SheetBoard";

export default async function Page({ searchParams }: { searchParams: Promise<{ enrollment?: string }> }) {
  const { enrollment } = await searchParams;
  const id = Number(enrollment);
  return (
    <AdminShell>
      <SheetBoard enrollmentId={Number.isSafeInteger(id) && id > 0 ? id : null} />
    </AdminShell>
  );
}
