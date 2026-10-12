import type { ProfileEditorSection } from '@/lib/profileEditing';
import { Button } from '@/components/ui/button';
import { useAdminRoles } from '@/hooks/useAdminRoles';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Briefcase, GraduationCap, Heart, MapPin, Globe, Phone, Shield } from 'lucide-react';
import { FlagChipRow } from '@/components/profile/FlagChip';

interface SecureProfileViewerProps {
  profile: Record<string, unknown>;
  isOwnProfile: boolean;
  onEdit?: (section: ProfileEditorSection, privacyField?: string) => void;
  editingSection?: ProfileEditorSection | null;
}

// Visibility is enforced server-side: for other users' profiles the data comes
// from get_public_profile_safe, which only includes a field when the viewer is
// allowed to see it (per-field *_public flags, identity/relationships section
// visibility, friends checks). Presence of a value IS the authorization — the
// old client-side PrivacyGuard re-check ran against privacy_settings the RPC
// never returned, so permitted fields were never rendered for other viewers.
export function SecureProfileViewer({
  profile,
  isOwnProfile,
  onEdit,
  editingSection,
}: SecureProfileViewerProps) {
  const { isAdmin } = useAdminRoles();

  if (!profile) return null;

  const str = (key: string) => {
    const v = profile[key];
    return typeof v === 'string' && v.trim() ? v : null;
  };

  const location = str('location');
  const pronouns = str('pronouns');
  const occupation = str('occupation');
  const education = str('education');
  const website = str('website');
  const phone = str('phone');
  const genderIdentity = str('gender_identity');
  const sexualOrientation = str('sexual_orientation');
  const relationshipStatus = str('current_relationship_status');
  const interests =
    Array.isArray(profile.interests) && profile.interests.length > 0
      ? (profile.interests as string[])
      : null;

  const hasSensitive = genderIdentity || sexualOrientation || relationshipStatus;

  return (
    <div className="flex flex-col gap-6">
      {/* Basic Information */}
      {editingSection !== 'profile' && (
        <Card>
          <CardHeader>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <CardTitle>Basic Information</CardTitle>
              {isOwnProfile && onEdit && (
                <div className="flex gap-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => onEdit('privacy', 'profile_visibility')}
                  >
                    Visibility
                  </Button>
                  <Button variant="outline" size="sm" onClick={() => onEdit('profile')}>
                    Edit
                  </Button>
                </div>
              )}
            </div>
          </CardHeader>
          <CardContent>
            <div className="flex flex-col gap-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {location && (
                  <div className="flex items-center gap-4">
                    <MapPin className="h-5 w-5 text-muted-foreground" />
                    <div>
                      <p className="text-sm font-medium">Location</p>
                      <p className="text-sm text-muted-foreground">{location}</p>
                    </div>
                  </div>
                )}

                {pronouns && (
                  <div>
                    <p className="text-sm font-medium">Pronouns</p>
                    <p className="text-sm text-muted-foreground">{pronouns}</p>
                  </div>
                )}

                {occupation && (
                  <div className="flex items-center gap-4">
                    <Briefcase className="h-5 w-5 text-muted-foreground" />
                    <div>
                      <p className="text-sm font-medium">Occupation</p>
                      <p className="text-sm text-muted-foreground">{occupation}</p>
                    </div>
                  </div>
                )}

                {education && (
                  <div className="flex items-center gap-4">
                    <GraduationCap className="h-5 w-5 text-muted-foreground" />
                    <div>
                      <p className="text-sm font-medium">Education</p>
                      <p className="text-sm text-muted-foreground">{education}</p>
                    </div>
                  </div>
                )}
              </div>

              {/* Server-gated like every field here: the RPC only returns
                identity_flags when flags_visibility allows this viewer. */}
              {Array.isArray(profile.identity_flags) && profile.identity_flags.length > 0 && (
                <div>
                  <p className="text-base font-medium mb-2">Flags</p>
                  <FlagChipRow flagIds={profile.identity_flags as string[]} />
                </div>
              )}

              {interests && (
                <div className="flex flex-col gap-4">
                  <div>
                    <p className="text-base font-medium mb-2">Interests</p>
                    <div className="flex flex-wrap gap-2">
                      {interests.map((interest, index) => (
                        <Badge key={index} variant="secondary">
                          {interest}
                        </Badge>
                      ))}
                    </div>
                  </div>
                </div>
              )}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Contact Information */}
      {editingSection !== 'profile' && (website || phone) && (
        <Card>
          <CardHeader>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <CardTitle>Contact Information</CardTitle>
              {isOwnProfile && onEdit && (
                <div className="flex gap-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => onEdit('privacy', 'contact_visibility')}
                  >
                    Visibility
                  </Button>
                  <Button variant="outline" size="sm" onClick={() => onEdit('profile')}>
                    Edit
                  </Button>
                </div>
              )}
            </div>
          </CardHeader>
          <CardContent>
            <div className="flex flex-col gap-4">
              {website && (
                <div className="flex items-center gap-4">
                  <Globe className="h-5 w-5 text-muted-foreground" />
                  <div>
                    <p className="text-sm font-medium">Website</p>
                    <a
                      href={website}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-primary hover:underline"
                    >
                      {website}
                    </a>
                  </div>
                </div>
              )}

              {phone && (
                <div className="flex items-center gap-4">
                  <Phone className="h-5 w-5 text-muted-foreground" />
                  <div>
                    <p className="text-sm font-medium">Phone</p>
                    <p className="text-sm text-muted-foreground">{phone}</p>
                  </div>
                </div>
              )}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Identity & relationship details — server only returns these when the
          profile's identity/relationships visibility allows this viewer */}
      {editingSection !== 'dating' && (isOwnProfile || hasSensitive) && (
        <Card>
          <CardHeader>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <CardTitle>
                <div className="flex items-center gap-2">
                  <Shield className="h-5 w-5" />
                  Identity & relationships
                  {!isOwnProfile && isAdmin && <Badge variant="destructive">Admin Access</Badge>}
                </div>
              </CardTitle>
              {isOwnProfile && onEdit && (
                <div className="flex gap-2">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => onEdit('privacy', 'identity_visibility')}
                  >
                    Visibility
                  </Button>
                  <Button variant="outline" size="sm" onClick={() => onEdit('dating')}>
                    Edit
                  </Button>
                </div>
              )}
            </div>
          </CardHeader>
          <CardContent>
            <div className="flex flex-col gap-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {genderIdentity && (
                  <div>
                    <p className="text-sm font-medium">Gender Identity</p>
                    <p className="text-sm text-muted-foreground">{genderIdentity}</p>
                  </div>
                )}

                {sexualOrientation && (
                  <div>
                    <p className="text-sm font-medium">Sexual Orientation</p>
                    <p className="text-sm text-muted-foreground">{sexualOrientation}</p>
                  </div>
                )}

                {relationshipStatus && (
                  <div className="flex items-center gap-4">
                    <Heart className="h-5 w-5 text-muted-foreground" />
                    <div>
                      <p className="text-sm font-medium">Relationship Status</p>
                      <p className="text-sm text-muted-foreground">{relationshipStatus}</p>
                    </div>
                  </div>
                )}
              </div>

              {!isOwnProfile && isAdmin && (
                <div className="border mt-4 p-4 bg-destructive/10 border-destructive rounded-element">
                  <p className="text-sm text-destructive font-medium">
                    Admin Access: This sensitive information is logged and monitored for security
                    compliance.
                  </p>
                </div>
              )}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
