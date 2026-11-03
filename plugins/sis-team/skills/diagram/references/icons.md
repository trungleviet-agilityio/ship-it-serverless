# draw.io icons for ship-it-safely

Every name below was rendered with the draw.io CLI and checked by eye. `check_drawio.py` rejects any
`mxgraph.aws4.*` name that is not in this file, so add a name here only after rendering it.

## Service icons (78x78, `strokeColor=#ffffff`)

Style: `sketch=0;outlineConnect=0;fontColor=#232F3E;fillColor=<fill>;strokeColor=#ffffff;dashed=0;verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=12;aspect=fixed;shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.<name>;`

| Service | `resIcon` name | fill |
|---|---|---|
| ECS | `mxgraph.aws4.ecs` | `#ED7100` |
| Fargate | `mxgraph.aws4.fargate` | `#ED7100` |
| ECR | `mxgraph.aws4.ecr` | `#ED7100` |
| S3 | `mxgraph.aws4.s3` | `#7AA116` |
| Secrets Manager | `mxgraph.aws4.secrets_manager` | `#DD344C` |
| IAM | `mxgraph.aws4.identity_and_access_management` | `#DD344C` |
| IAM Identity Center | `mxgraph.aws4.single_sign_on` | `#DD344C` |
| CloudWatch | `mxgraph.aws4.cloudwatch_2` | `#E7157B` |
| CloudTrail | `mxgraph.aws4.cloudtrail` | `#E7157B` |
| Organizations | `mxgraph.aws4.organizations` | `#E7157B` |
| Budgets | `mxgraph.aws4.budgets` | `#7AA116` |
| EventBridge | `mxgraph.aws4.eventbridge` | `#E7157B` |
| SNS | `mxgraph.aws4.sns` | `#E7157B` |

## Resource icons (78x78 or 48x48, `strokeColor=none`)

Style: `sketch=0;outlineConnect=0;fontColor=#232F3E;fillColor=<fill>;strokeColor=none;dashed=0;verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=12;aspect=fixed;pointerEvents=1;shape=mxgraph.aws4.<name>;`

| Resource | `shape` name | fill |
|---|---|---|
| Application Load Balancer | `mxgraph.aws4.application_load_balancer` | `#8C4FFF` |
| Internet Gateway | `mxgraph.aws4.internet_gateway` | `#8C4FFF` |
| IAM role | `mxgraph.aws4.role` | `#DD344C` |
| STS | `mxgraph.aws4.sts` | `#DD344C` |
| IAM permissions (policy) | `mxgraph.aws4.permissions` | `#DD344C` |
| S3 bucket | `mxgraph.aws4.bucket` | `#7AA116` |
| ECS service | `mxgraph.aws4.ecs_service` | `#ED7100` |
| ECS task | `mxgraph.aws4.ecs_task` | `#ED7100` |
| ECR registry | `mxgraph.aws4.registry` | `#ED7100` |
| CloudWatch alarm | `mxgraph.aws4.alarm` | `#E7157B` |
| Users | `mxgraph.aws4.users` | `#232F3D` |
| Client / browser | `mxgraph.aws4.client` | `#232F3D` |
| EventBridge rule | `mxgraph.aws4.rule_3` | `#E7157B` |
| Email notification | `mxgraph.aws4.email_notification` | `#E7157B` |

Do not mix the two patterns: a service icon without `strokeColor=#ffffff` loses its glyph, and a resource
icon with it renders wrong.

## Groups (always `container=1`, `fillColor=none` unless noted)

Style: `outlineConnect=0;gradientColor=none;html=1;whiteSpace=wrap;fontSize=12;fontStyle=0;container=1;pointerEvents=0;collapsible=0;recursiveResize=0;shape=mxgraph.aws4.group;grIcon=mxgraph.aws4.<grIcon>;strokeColor=<color>;fillColor=none;verticalAlign=top;align=left;spacingLeft=30;fontColor=<color>;dashed=0;`

| Group | `grIcon` | color |
|---|---|---|
| AWS Cloud | `mxgraph.aws4.group_aws_cloud_alt` | `#232F3E` |
| AWS account | `mxgraph.aws4.group_account` | `#CD2264` |
| VPC | `mxgraph.aws4.group_vpc2` | `#8C4FFF` |
| Public subnet | `mxgraph.aws4.group_security_group` | `#7AA116`, with `grStroke=0;fillColor=#F2F6E8;fontColor=#248814;` |

`group_public_subnet` renders without its icon; use the public subnet row above.

## Not AWS

GitHub, GitHub Actions and the developer laptop have no AWS icon. Use a labeled rounded box:
`rounded=1;whiteSpace=wrap;html=1;fillColor=#24292F;strokeColor=none;fontColor=#FFFFFF;fontSize=12;`
(GitHub) or the `client` resource icon (laptop).

## Edges

Base: `edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeWidth=2;strokeColor=#545B64;endArrow=block;endFill=1;`

| Meaning | Add |
|---|---|
| Main request or deploy flow | nothing |
| Assume role / auth (OIDC, STS) | `dashed=1;strokeColor=#DD344C;` |
| Planned, not in code yet | `dashed=1;dashPattern=1 4;strokeColor=#879196;` |
| Label | `labelBackgroundColor=#FFFFFF;fontSize=11;` (1 to 3 words) |

## Page skeleton

```xml
<mxfile host="drawio">
  <diagram id="main" name="Overview">
    <mxGraphModel dx="1600" dy="900" grid="1" gridSize="10" guides="1" page="1" pageWidth="1600" pageHeight="900" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <mxCell id="bg" value="" style="rounded=0;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor=none;" vertex="1" parent="1">
          <mxGeometry x="0" y="0" width="1600" height="900" as="geometry" />
        </mxCell>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
```
