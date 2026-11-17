export interface PackageProperty {
  id: string
  title: string
  kind: 'text' | 'integer' | 'toggle' | 'input' | 'module'
  initial: string | null
  minimum: number | null
  maximum: number | null
}

export interface PackageComponent {
  id: string
  kind: 'board' | 'service'
  title: string
  detail: string
  properties: PackageProperty[]
}

export interface ComponentProvider {
  id: string
  name: string
  components: PackageComponent[]
}

export interface PackageCatalog {
  providers: ComponentProvider[]
  recommendations: { name: string; suggested_by: string }[]
}

export interface PackageReference {
  provider: string
  type: string
  enabled?: boolean
  properties?: Record<string, string>
}

export function packageDefinition(providers: ComponentProvider[], reference?: PackageReference) {
  return providers.find(provider => provider.id === reference?.provider)?.components.find(component => component.id === reference?.type)
}

export function packageColor(provider: string) {
  let hue = 0
  for (const character of provider) hue = (hue * 31 + character.charCodeAt(0)) % 360
  return { '--package-accent': `hsl(${hue} 55% 55%)` }
}
