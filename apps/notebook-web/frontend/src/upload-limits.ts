export const guestUpload = {
  fileBytes: 256 * 1024,
  batchBytes: 1024 * 1024,
  fileLabel: '256 KiB',
  batchLabel: '1 MiB',
} as const

export function base64ByteLength(data: string): number {
  return data.length * 3 / 4 - (data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0)
}
