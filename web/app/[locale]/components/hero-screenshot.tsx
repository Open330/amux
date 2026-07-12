import Image from "next/image";

export function HeroScreenshot({
  alt,
  background = false,
}: {
  alt: string;
  background?: boolean;
}) {
  if (background) {
    return (
      <div className="absolute inset-0">
        <Image
          src="/amux-workspaces.png"
          alt={alt}
          fill
          priority
          quality={85}
          sizes="100vw"
          className="object-cover object-[center_32%]"
        />
      </div>
    );
  }

  return (
    <div className="relative">
      {/* drop-shadow (not box-shadow): box-shadow traces the rectangular
          element box and would square off the corners, showing through the
          image's transparent rounded corners. drop-shadow follows the alpha
          channel, so the shadow hugs the real window corners. */}
      <Image
        src="/amux-workspaces.png"
        alt={alt}
        width={1553}
        height={1013}
        quality={85}
        // The screenshot caps at 90rem (1440px) wide and is full-width below
        // that, so tell the browser not to fetch oversized variants on large
        // displays (keeps image transformations and bytes down).
        sizes="(min-width: 1440px) 1440px, 100vw"
        className="w-full [filter:drop-shadow(0_24px_44px_rgba(0,0,0,0.55))]"
      />
    </div>
  );
}
