import StudentFlow from "@/components/StudentFlow";

export default async function CampusPage({ params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  return <StudentFlow code={code} />;
}
