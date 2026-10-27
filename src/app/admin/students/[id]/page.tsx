import { notFound } from "next/navigation";
import AdminShell from "@/components/AdminShell";
import StudentRecord from "@/components/StudentRecord";

export default async function StudentPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ date?: string }>;
}) {
  const { id } = await params;
  const { date } = await searchParams;
  const enrollmentId = Number(id);
  if (!Number.isSafeInteger(enrollmentId) || enrollmentId <= 0) notFound();
  return (
    <AdminShell>
      <StudentRecord enrollmentId={enrollmentId} initialDate={date && /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : undefined} />
    </AdminShell>
  );
}
