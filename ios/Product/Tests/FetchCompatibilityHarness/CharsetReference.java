import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
public class CharsetReference {
  public static void main(String[] args) {
    String[] names={"UTF-8","UTF-16BE","UTF-16BE","UTF-32BE","UTF-32BE","US-ASCII","UTF-16","UTF-32","Shift_JIS","windows-1252"};
    int[][] values={{65,195,40},{0,65,216,0,0},{216,0,0,65},{0,0,216,0},{0,0,0,65,0},{65,233,66},{0,67,0,101,0,100,0,97,0,114},{0,0,0,67},{130,32},{65,129,66}};
    System.out.println("[");
    for(int i=0;i<names.length;i++) {
      byte[] b=new byte[values[i].length];for(int n=0;n<b.length;n++)b[n]=(byte)values[i][n];
      String decoded=new String(b,Charset.forName(names[i]));
      System.out.print("{\"charset\":\""+names[i]+"\",\"hex\":\"");for(byte n:b)System.out.printf("%02x",n&255);
      System.out.print("\",\"codePoints\":[");int[] points=decoded.codePoints().toArray();for(int n=0;n<points.length;n++)System.out.print((n==0?"":",")+points[n]);System.out.print("]}");System.out.println(i==names.length-1?"":",");
    }
    System.out.println("]");
  }
}
